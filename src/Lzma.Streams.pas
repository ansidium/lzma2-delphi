unit Lzma.Streams;

interface

uses
  System.Classes,
  System.SysUtils,
  Lzma.Types;

function ReadByteRequired(const Source: TStream): Byte;
function ReadAvailable(const Source: TStream; var Buffer; const Count: NativeUInt): Integer;
procedure ReadExact(const Source: TStream; var Buffer; const Count: NativeUInt);
procedure WriteExact(const Destination: TStream; const Buffer; const Count: NativeUInt);
function ReadAllBytes(const Source: TStream; const BufferSize: NativeUInt = 1048576): TBytes;
function ReadAllBytesBounded(const Source: TStream; const LimitBytes: UInt64; const ErrorMessage: string;
  const BufferSize: NativeUInt = 1048576): TBytes;
procedure WriteBytes(const Destination: TStream; const Data: TBytes);
procedure ReportProgress(const Progress: TLzma2ProgressEvent; const InBytes, OutBytes: UInt64);

implementation

uses
  Lzma.Errors,
  Lzma.Alloc;

function ReadAvailable(const Source: TStream; var Buffer; const Count: NativeUInt): Integer;
var
  Request: Integer;
begin
  Result := 0;
  if Count = 0 then
    Exit(0);
  if Count > NativeUInt(High(Integer)) then
    Request := High(Integer)
  else
    Request := Integer(Count);
  try
    Result := Source.Read(Buffer, Request);
  except
    on E: ELzmaError do
      raise;
    on E: Exception do
      RaiseLzmaError(SZ_ERROR_READ, 'Input stream read failed: ' + E.Message);
  end;
  if Result < 0 then
    RaiseLzmaError(SZ_ERROR_READ, 'Input stream read failed');
end;

function ReadByteRequired(const Source: TStream): Byte;
begin
  if ReadAvailable(Source, Result, 1) <> 1 then
    RaiseLzmaError(SZ_ERROR_INPUT_EOF, 'Unexpected end of input stream');
end;

procedure ReadExact(const Source: TStream; var Buffer; const Count: NativeUInt);
var
  Done: NativeUInt;
  Chunk: Integer;
  P: PByte;
begin
  Done := 0;
  P := @Buffer;
  while Done < Count do
  begin
    Chunk := ReadAvailable(Source, P[Done], Count - Done);
    if Chunk = 0 then
      RaiseLzmaError(SZ_ERROR_INPUT_EOF, 'Unexpected end of input stream');
    Inc(Done, NativeUInt(Chunk));
  end;
end;

procedure WriteExact(const Destination: TStream; const Buffer; const Count: NativeUInt);
begin
  try
    if Count <> 0 then
      Destination.WriteBuffer(Buffer, Count);
  except
    on E: Exception do
      RaiseLzmaError(SZ_ERROR_WRITE, 'Output stream write failed: ' + E.Message);
  end;
end;

function ReadAllBytesBounded(const Source: TStream; const LimitBytes: UInt64; const ErrorMessage: string;
  const BufferSize: NativeUInt): TBytes;
var
  Temp: TMemoryStream;
  Buffer: TBytes;
  Count: Integer;
  Size: NativeUInt;
  Total: UInt64;
begin
  Temp := TMemoryStream.Create;
  try
    Size := CheckedBufferSize(BufferSize);
    SetLength(Buffer, Size);
    Total := 0;
    repeat
      Count := ReadAvailable(Source, Buffer[0], Length(Buffer));
      if Count > 0 then
      begin
        if UInt64(Count) > LimitBytes - Total then
          RaiseLzmaError(SZ_ERROR_MEM, ErrorMessage);
        Inc(Total, UInt64(Count));
        if Total > UInt64(High(NativeInt)) then
          RaiseLzmaError(SZ_ERROR_MEM, 'Input stream exceeds native TBytes capacity');
        Temp.WriteBuffer(Buffer[0], Count);
      end;
    until Count = 0;

    SetLength(Result, NativeInt(Total));
    if Total > 0 then
    begin
      Temp.Position := 0;
      Temp.ReadBuffer(Result[0], Temp.Size);
    end;
  finally
    Temp.Free;
  end;
end;

function ReadAllBytes(const Source: TStream; const BufferSize: NativeUInt): TBytes;
begin
  Result := ReadAllBytesBounded(Source, High(UInt64), 'Input stream exceeds native memory limit', BufferSize);
end;

procedure WriteBytes(const Destination: TStream; const Data: TBytes);
begin
  if Length(Data) <> 0 then
    WriteExact(Destination, Data[0], Length(Data));
end;

procedure ReportProgress(const Progress: TLzma2ProgressEvent; const InBytes, OutBytes: UInt64);
var
  Cancel: Boolean;
begin
  if not Assigned(Progress) then
    Exit;
  Cancel := False;
  Progress(InBytes, OutBytes, Cancel);
  if Cancel then
    RaiseLzmaError(SZ_ERROR_PROGRESS, 'Operation cancelled');
end;

end.
