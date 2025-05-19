unit FL2Pool;

interface

uses
  System.SysUtils, System.SyncObjs, System.Classes,
  System.Generics.Collections;

type
  // Тип функции задачи
  FL2POOL_function = procedure(opaque: Pointer; n: PtrInt);
  // Указатель на контекст пула
  PFL2POOL_ctx = Pointer;

  // Создаёт пул потоков (numThreads = количество потоков)
  function FL2POOL_create(numThreads: NativeUInt): PFL2POOL_ctx;
  // Уничтожает пул
  procedure FL2POOL_free(ctx: PFL2POOL_ctx);
  // Возвращает примерный размер занимаемой пулом памяти
  function FL2POOL_sizeOf(ctx: PFL2POOL_ctx): NativeUInt;
  // Добавляет одну задачу (func) с индексом n в пул
  procedure FL2POOL_add(ctx: PFL2POOL_ctx; func: FL2POOL_function; opaque: Pointer; n: PtrInt);
  // Добавляет пакет задач в диапазоне [first..last-1]
  procedure FL2POOL_addRange(ctx: PFL2POOL_ctx; func: FL2POOL_function; opaque: Pointer; first, last: PtrInt);
  // Ожидает выполнения всех задач, возвращает 0 при успехе (или если все уже выполнены), 1 при таймауте
  function FL2POOL_waitAll(ctx: PFL2POOL_ctx; timeout: Cardinal): Integer;
  // Возвращает число задач, которые в данный момент исполняются
  function FL2POOL_threadsBusy(ctx: PFL2POOL_ctx): NativeUInt;

implementation

type
  // Внутренний "задание" (job)
  TFL2Job = record
    Func: FL2POOL_function;
    Opaque: Pointer;
    Index: PtrInt;
  end;

  // Класс пула потоков
  TFL2Pool = class
  private
    FQueue: TQueue<TFL2Job>;
    FCrit: TCriticalSection;
    FJobEvent: TEvent;
    FBusyEvent: TEvent;
    FThreads: array of TThread;
    FShutdown: Boolean;
    FBusy: Integer;
    function DequeueJob(out Job: TFL2Job): Boolean;
    procedure FinishedJob;
  public
    constructor Create(NumThreads: Integer);
    destructor Destroy; override;
    procedure Add(Func: FL2POOL_function; Opaque: Pointer; N: PtrInt);
    procedure AddRange(Func: FL2POOL_function; Opaque: Pointer; First, Last: PtrInt);
    function WaitAll(Timeout: Cardinal): Boolean;
    function ThreadsBusy: Cardinal;
    function SizeOfContext: NativeUInt;
  end;

  // Поток-воркер, который выбирает задания из очереди
  TFL2Worker = class(TThread)
  private
    FPool: TFL2Pool;
  protected
    procedure Execute; override;
  public
    constructor Create(APool: TFL2Pool);
  end;

{ TFL2Worker }

constructor TFL2Worker.Create(APool: TFL2Pool);
begin
  FPool := APool;
  // Запуск сразу, False = не в "suspended"
  inherited Create(False);
end;

procedure TFL2Worker.Execute;
var
  Job: TFL2Job;
begin
  while not Terminated do
  begin
    // Пытаемся взять задание
    if not FPool.DequeueJob(Job) then
    begin
      // Если пул завершает работу — выходим
      if FPool.FShutdown then
        Break;
      // Иначе ждём сигнала о появлении новой задачи
      FPool.FJobEvent.WaitFor(INFINITE);
      Continue;
    end;
    try
      // Выполнить задание
      Job.Func(Job.Opaque, Job.Index);
    finally
      // Сообщить пулу о завершении одного задания
      FPool.FinishedJob;
    end;
  end;
end;

{ TFL2Pool }

constructor TFL2Pool.Create(NumThreads: Integer);
var
  i: Integer;
begin
  inherited Create;
  FQueue := TQueue<TFL2Job>.Create;
  FCrit := TCriticalSection.Create;
  // Событие для сигнализации о новых заданиях
  FJobEvent := TEvent.Create(nil, False, False, '');
  // Событие для ожидания "все задания выполнены"
  // AutoReset = False, InitiallySignaled = True
  FBusyEvent := TEvent.Create(nil, True, True, '');
  FShutdown := False;
  FBusy := 0;
  SetLength(FThreads, NumThreads);
  for i := 0 to NumThreads - 1 do
    FThreads[i] := TFL2Worker.Create(Self);
end;

destructor TFL2Pool.Destroy;
var
  Worker: TThread;
begin
  // Сигнализируем о завершении, чтобы все воркеры вышли
  FShutdown := True;
  FJobEvent.SetEvent;
  // Ждём закрытия потоков
  for Worker in FThreads do
  begin
    Worker.Terminate;
    Worker.WaitFor;
    Worker.Free;
  end;
  FCrit.Free;
  FJobEvent.Free;
  FBusyEvent.Free;
  FQueue.Free;
  inherited;
end;

function TFL2Pool.DequeueJob(out Job: TFL2Job): Boolean;
begin
  FCrit.Enter;
  try
    if FQueue.Count > 0 then
    begin
      Job := FQueue.Dequeue;
      Inc(FBusy);
      // Теперь пул "не пуст" — сбросим событие "все свободны"
      FBusyEvent.ResetEvent;
      Result := True;
    end
    else
      Result := False;
  finally
    FCrit.Leave;
  end;
end;

procedure TFL2Pool.FinishedJob;
begin
  FCrit.Enter;
  try
    Dec(FBusy);
    // Если нет активных заданий и в очереди пусто — "все выполнено"
    if (FBusy = 0) and (FQueue.Count = 0) then
      FBusyEvent.SetEvent;
  finally
    FCrit.Leave;
  end;
end;

procedure TFL2Pool.Add(Func: FL2POOL_function; Opaque: Pointer; N: PtrInt);
var
  Job: TFL2Job;
begin
  FCrit.Enter;
  try
    Job.Func := Func;
    Job.Opaque := Opaque;
    Job.Index := N;
    FQueue.Enqueue(Job);
    // Поскольку добавили новую задачу — сбрасываем сигнал "все готово"
    FBusyEvent.ResetEvent;
  finally
    FCrit.Leave;
  end;
  // Сигнализируем воркерам, что есть новая работа
  FJobEvent.SetEvent;
end;

procedure TFL2Pool.AddRange(Func: FL2POOL_function; Opaque: Pointer; First, Last: PtrInt);
var
  N: PtrInt;
begin
  for N := First to Last - 1 do
    Add(Func, Opaque, N);
end;

function TFL2Pool.WaitAll(Timeout: Cardinal): Boolean;
begin
  // Ждём, пока FBusyEvent не встанет в Signaled (все задания выполнены) либо истечёт таймаут
  Result := (FBusyEvent.WaitFor(Timeout) = wrSignaled);
end;

function TFL2Pool.ThreadsBusy: Cardinal;
begin
  FCrit.Enter;
  try
    Result := FBusy;
  finally
    FCrit.Leave;
  end;
end;

function TFL2Pool.SizeOfContext: NativeUInt;
begin
  // Примерный расчёт: размер самого объекта + указатели на потоки + объём очереди
  Result := SizeOf(Self)
            + NativeUInt(Length(FThreads)) * SizeOf(Pointer)
            + NativeUInt(FQueue.Count) * SizeOf(TFL2Job);
end;

{ Переходные функции API }

function FL2POOL_create(numThreads: NativeUInt): PFL2POOL_ctx;
begin
  Result := PFL2POOL_ctx(TFL2Pool.Create(numThreads));
end;

procedure FL2POOL_free(ctx: PFL2POOL_ctx);
begin
  if ctx <> nil then
    TFL2Pool(ctx).Free;
end;

function FL2POOL_sizeOf(ctx: PFL2POOL_ctx): NativeUInt;
begin
  if ctx <> nil then
    Result := TFL2Pool(ctx).SizeOfContext
  else
    Result := 0;
end;

procedure FL2POOL_add(ctx: PFL2POOL_ctx; func: FL2POOL_function; opaque: Pointer; n: PtrInt);
begin
  if ctx <> nil then
    TFL2Pool(ctx).Add(func, opaque, n);
end;

procedure FL2POOL_addRange(ctx: PFL2POOL_ctx; func: FL2POOL_function; opaque: Pointer; first, last: PtrInt);
begin
  if ctx <> nil then
    TFL2Pool(ctx).AddRange(func, opaque, first, last);
end;

function FL2POOL_waitAll(ctx: PFL2POOL_ctx; timeout: Cardinal): Integer;
begin
  // Возвращаем 0 при успехе, 1 — при таймауте
  if ctx = nil then
    Exit(0);
  if TFL2Pool(ctx).WaitAll(timeout) then
    Result := 0
  else
    Result := 1;
end;

function FL2POOL_threadsBusy(ctx: PFL2POOL_ctx): NativeUInt;
begin
  if ctx <> nil then
    Result := TFL2Pool(ctx).ThreadsBusy
  else
    Result := 0;
end;

end.
