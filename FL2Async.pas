unit FL2Async;

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs,
  FL2Pool, FL2Helpers;

type
  TFL2AsyncCompressionResult = class
  private
    FEvent: TEvent;
    FData: TBytes;
  public
    constructor Create;
    destructor Destroy; override;
    procedure SetData(const AData: TBytes);
    function WaitFor(Timeout: Cardinal = INFINITE): TBytes;
  end;

  TFL2AsyncCompressor = class
  private
    FPool: PFL2POOL_ctx;
  public
    constructor Create(ThreadCount: Cardinal);
    destructor Destroy; override;
    function CompressBytesAsync(const Input: TBytes; Level: Integer): TFL2AsyncCompressionResult;
  end;

implementation

{ TFL2AsyncCompressionResult }

constructor TFL2AsyncCompressionResult.Create;
begin
  inherited Create;
  FEvent := TEvent.Create(nil, True, False, '');
end;

destructor TFL2AsyncCompressionResult.Destroy;
begin
  FEvent.Free;
  inherited Destroy;
end;

procedure TFL2AsyncCompressionResult.SetData(const AData: TBytes);
begin
  FData := AData;
  FEvent.SetEvent;
end;

function TFL2AsyncCompressionResult.WaitFor(Timeout: Cardinal): TBytes;
begin
  FEvent.WaitFor(Timeout);
  Result := FData;
end;

{ Internal job record }

type
  TFL2CompressJob = class
  public
    Input: TBytes;
    Level: Integer;
    ResultObj: TFL2AsyncCompressionResult;
  end;

procedure CompressJob(opaque: Pointer; n: NativeInt);
var
  Job: TFL2CompressJob;
  Output: TBytes;
begin
  Job := TFL2CompressJob(opaque);
  try
    Output := FL2CompressBytes(Job.Input, Job.Level);
    Job.ResultObj.SetData(Output);
  finally
    Job.Free;
  end;
end;

{ TFL2AsyncCompressor }

constructor TFL2AsyncCompressor.Create(ThreadCount: Cardinal);
begin
  inherited Create;
  FPool := FL2POOL_create(ThreadCount);
  if FPool = nil then
    raise Exception.Create('Failed to create FL2 thread pool');
end;

destructor TFL2AsyncCompressor.Destroy;
begin
  FL2POOL_free(FPool);
  inherited Destroy;
end;

function TFL2AsyncCompressor.CompressBytesAsync(const Input: TBytes; Level: Integer): TFL2AsyncCompressionResult;
var
  Job: TFL2CompressJob;
begin
  Result := TFL2AsyncCompressionResult.Create;
  Job := TFL2CompressJob.Create;
  Job.Input := Copy(Input, 0, Length(Input));
  Job.Level := Level;
  Job.ResultObj := Result;
  FL2POOL_add(FPool, CompressJob, Job, 0);
end;

end.

