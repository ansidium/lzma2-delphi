unit FL2Pool;

interface

uses
  System.SysUtils;

type
  // Единый тип процедуры-обработчика
  TFL2PoolFunction = procedure(opaque: Pointer; n: NativeInt);

  // Основной класс пула потоков
  TFL2POOL_ctx = class
  private
    FNumThreads: Integer;       // Количество потоков
    FFunction: TFL2PoolFunction; 
    FOpaque: Pointer;           // Дополнительные данные
    FQueueIndex: NativeInt;     // Текущий индекс задачи
    FQueueEnd: NativeInt;       // Конечный индекс (не включая)
    FBusyCount: Integer;        // Сколько потоков сейчас занято
    FShutdown: Boolean;         // Флаг завершения пула
    FLock: TObject;             // Объект для TMonitor
    FThreads: array of TThread; // Список потоков

    // Закрытый метод, который вызывают рабочие потоки
    procedure WorkerExecute; 
  public
    constructor Create(numThreads: Integer);
    destructor Destroy; override;

    // Добавить интервал задач [first..last), каждая задача имеет номер n
    procedure AddRange(func: TFL2PoolFunction; opaque: Pointer; first, last: NativeInt);

    // Добавить одиночную задачу с номером n
    procedure Add(func: TFL2PoolFunction; opaque: Pointer; n: NativeInt);

    // Дождаться выполнения всех задач; timeout = 0 => бесконечное ожидание.
    // Возвращает 0, если все задачи выполнены, или 1 — если истек таймаут.
    function WaitAll(timeout: Cardinal): Integer;

    // Возвращает количество потоков, которые сейчас заняты выполнением задач
    function ThreadsBusy: NativeInt;
  end;

// Внешние функции, работающие через TFL2POOL_ctx как Pointer
function FL2POOL_create(numThreads: NativeInt): Pointer;
procedure FL2POOL_free(ctx: Pointer);
function FL2POOL_sizeof(ctx: Pointer): NativeUInt;

procedure FL2POOL_addRange(ctx: Pointer; func: TFL2PoolFunction; opaque: Pointer; first, last: NativeInt);
procedure FL2POOL_add(ctx: Pointer; func: TFL2PoolFunction; opaque: Pointer; n: NativeInt);

// Функции ожидания и проверки занятости
function FL2POOL_waitAll(ctx: Pointer; timeout: Cardinal): Integer;
function FL2POOL_threadsBusy(ctx: Pointer): NativeInt;

implementation

uses
  System.Classes; // для TThread и TMonitor

type
  // Поток-работник пула 
  TFL2WorkerThread = class(TThread)
  private
    FPool: TFL2POOL_ctx;
  protected
    procedure Execute; override;
  public
    constructor Create(APool: TFL2POOL_ctx);
  end;

{ ---------------- TFL2WorkerThread ---------------- }

constructor TFL2WorkerThread.Create(APool: TFL2POOL_ctx);
begin
  FPool := APool;
  inherited Create(False); // Запуск потока сразу
  FreeOnTerminate := False;
end;

procedure TFL2WorkerThread.Execute;
begin
  // Вызов приватного метода WorkerExecute у TFL2POOL_ctx
  FPool.WorkerExecute;
end;

{ --------------- TFL2POOL_ctx методы --------------- }

constructor TFL2POOL_ctx.Create(numThreads: Integer);
var
  i: Integer;
begin
  inherited Create;

  if numThreads < 1 then
    numThreads := 1;
  FNumThreads := numThreads;

  FLock := TObject.Create;  // для TMonitor
  FFunction := nil;
  FOpaque := nil;
  FQueueIndex := 0;
  FQueueEnd := 0;
  FBusyCount := 0;
  FShutdown := False;

  // Создаём и запускаем потоки
  SetLength(FThreads, FNumThreads);
  for i := 0 to FNumThreads - 1 do
    FThreads[i] := TFL2WorkerThread.Create(Self);
end;

destructor TFL2POOL_ctx.Destroy;
var
  i: Integer;
begin
  // Уведомляем потоки о завершении
  TMonitor.Enter(FLock);
  try
    FShutdown := True;
    TMonitor.PulseAll(FLock);
  finally
    TMonitor.Exit(FLock);
  end;

  // Ждём, пока все потоки завершатся
  for i := 0 to Length(FThreads) - 1 do
  begin
    if Assigned(FThreads[i]) then
    begin
      FThreads[i].WaitFor;
      FThreads[i].Free;
    end;
  end;

  FLock.Free;
  inherited Destroy;
end;

// Приватный метод, в котором крутятся рабочие потоки
procedure TFL2POOL_ctx.WorkerExecute;
var
  n: NativeInt;
begin
  while True do
  begin
    TMonitor.Enter(FLock);
    try
      // Ждём задачу, если её нет
      while (FQueueIndex >= FQueueEnd) and not FShutdown do
        TMonitor.Wait(FLock);
      if FShutdown then
        Exit;
      // Берём текущий индекс задачи
      n := FQueueIndex;
      Inc(FQueueIndex);
      Inc(FBusyCount);
    finally
      TMonitor.Exit(FLock);
    end;

    // Выполняем саму задачу
    try
      if Assigned(FFunction) then
        FFunction(FOpaque, n);
    except
      // Логируем или игнорируем — на усмотрение
    end;

    // Задача выполнена, уменьшаем счётчик занятых потоков
    TMonitor.Enter(FLock);
    try
      Dec(FBusyCount);
      // Если все потоки освободились и очередь пустая, пробуждаем WaitAll
      if (FBusyCount = 0) and (FQueueIndex >= FQueueEnd) then
        TMonitor.PulseAll(FLock);
    finally
      TMonitor.Exit(FLock);
    end;
  end;
end;

procedure TFL2POOL_ctx.AddRange(func: TFL2PoolFunction; opaque: Pointer; first, last: NativeInt);
begin
  if not Assigned(func) then
    Exit;
  TMonitor.Enter(FLock);
  try
    FFunction := func;
    FOpaque := opaque;
    FQueueIndex := first;
    FQueueEnd := last;
    // Сигнализируем потокам, что появились новые задачи
    TMonitor.PulseAll(FLock);
  finally
    TMonitor.Exit(FLock);
  end;
end;

procedure TFL2POOL_ctx.Add(func: TFL2PoolFunction; opaque: Pointer; n: NativeInt);
begin
  // Добавляем задачу как интервал [n..n+1)
  AddRange(func, opaque, n, n + 1);
end;

function TFL2POOL_ctx.WaitAll(timeout: Cardinal): Integer;
var
  start: UInt64;
  remaining: Cardinal;
begin
  start := GetTickCount64;
  TMonitor.Enter(FLock);
  try
    // Ждём, пока все занятые потоки не освободятся и очередь не опустеет
    while (FBusyCount > 0) or (FQueueIndex < FQueueEnd) do
    begin
      if FShutdown then
        Break;

      // Бесконечное ожидание, если timeout = 0
      if timeout = 0 then
      begin
        TMonitor.Wait(FLock);
      end
      else
      begin
        // Сколько времени осталось
        remaining := timeout - Cardinal(GetTickCount64 - start);
        if Integer(remaining) <= 0 then
          Exit(1); // истёк таймаут

        // Ждём оставшееся время
        if not TMonitor.Wait(FLock, remaining) then
          Exit(1);
      end;
    end;
  finally
    TMonitor.Exit(FLock);
  end;
  Result := 0; // все задачи выполнены
end;

function TFL2POOL_ctx.ThreadsBusy: NativeInt;
begin
  TMonitor.Enter(FLock);
  try
    Result := FBusyCount;
  finally
    TMonitor.Exit(FLock);
  end;
end;

{ ------------------ Внешние функции ------------------ }

function FL2POOL_create(numThreads: NativeInt): Pointer;
begin
  Result := TFL2POOL_ctx.Create(numThreads);
end;

procedure FL2POOL_free(ctx: Pointer);
begin
  if Assigned(ctx) then
    TObject(ctx).Free;
end;

function FL2POOL_sizeof(ctx: Pointer): NativeUInt;
var
  pool: TFL2POOL_ctx;
begin
  if not Assigned(ctx) then
    Exit(0);
  pool := TFL2POOL_ctx(ctx);
  // Условно считаем: размер записи самого класса + место под массив потоков.
  // На самом деле реальное использование памяти будет больше (объекты TThread).
  Result := SizeOf(TFL2POOL_ctx) + pool.FNumThreads * SizeOf(Pointer);
end;

procedure FL2POOL_addRange(ctx: Pointer; func: TFL2PoolFunction; opaque: Pointer; first, last: NativeInt);
begin
  if Assigned(ctx) then
    TFL2POOL_ctx(ctx).AddRange(func, opaque, first, last);
end;

procedure FL2POOL_add(ctx: Pointer; func: TFL2PoolFunction; opaque: Pointer; n: NativeInt);
begin
  if Assigned(ctx) then
    TFL2POOL_ctx(ctx).Add(func, opaque, n);
end;

function FL2POOL_waitAll(ctx: Pointer; timeout: Cardinal): Integer;
begin
  if Assigned(ctx) then
    Result := TFL2POOL_ctx(ctx).WaitAll(timeout)
  else
    Result := 0; 
end;

function FL2POOL_threadsBusy(ctx: Pointer): NativeInt;
begin
  if Assigned(ctx) then
    Result := TFL2POOL_ctx(ctx).ThreadsBusy
  else
    Result := 0;
end;

end.
