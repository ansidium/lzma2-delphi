unit Lzma.Api;

interface

uses
  System.Classes,
  System.SysUtils,
  System.Threading,
  Lzma.Types;

type
  TLzma2 = class
  public
    class function DefaultOptions: TLzma2Options; static;
    class function DefaultOptionsFor(const Container: TLzma2Container; const Level: TLzma2CompressionLevel = 6;
      const ThreadCount: Integer = 1): TLzma2Options; static;
    class function XzOptions(const Level: TLzma2CompressionLevel = 6; const ThreadCount: Integer = 1;
      const Check: TLzma2Check = lzCheckCrc64): TLzma2Options; static;
    class function RawLzma2Options(const Level: TLzma2CompressionLevel = 6; const ThreadCount: Integer = 1): TLzma2Options; static;
    class function StandaloneLzmaOptions(const Level: TLzma2CompressionLevel = 6;
      const EndMarker: Boolean = False): TLzma2Options; static;
    class function SevenZipOptions(const ArchiveFileName: string = ''; const Level: TLzma2CompressionLevel = 6;
      const ThreadCount: Integer = 1): TLzma2Options; static;
    class function FastOptionsFor(const Container: TLzma2Container; const ThreadCount: Integer = 1): TLzma2Options; static;
    class function MaxOptionsFor(const Container: TLzma2Container; const ThreadCount: Integer = 1): TLzma2Options; static;
    class procedure Compress(Source: TStream; Destination: TStream; const Options: TLzma2Options;
      const Progress: TLzma2ProgressEvent = nil); static;
    class procedure Decompress(Source: TStream; Destination: TStream; const Options: TLzma2Options;
      const Progress: TLzma2ProgressEvent = nil); static;
    class procedure CompressFile(const SourceFileName, DestinationFileName: string; const Options: TLzma2Options;
      const Progress: TLzma2ProgressEvent = nil); static;
    class procedure DecompressFile(const SourceFileName, DestinationFileName: string; const Options: TLzma2Options;
      const Progress: TLzma2ProgressEvent = nil); static;
    class function CompressAsync(Source: TStream; Destination: TStream; const Options: TLzma2Options;
      const Progress: TLzma2ProgressEvent = nil): ITask; static;
    class function DecompressAsync(Source: TStream; Destination: TStream; const Options: TLzma2Options;
      const Progress: TLzma2ProgressEvent = nil): ITask; static;
  end;

implementation

uses
  Lzma.Errors,
  Lzma2.Encoder,
  Lzma2.Decoder,
  Lzma.Lzma,
  Lzma.Xz,
  Lzma.SevenZip;

class function TLzma2.DefaultOptions: TLzma2Options;
begin
  Result.Level := 6;
  Result.DictionarySize := DefaultDictionaryForLevel(Result.Level);
  Result.ThreadCount := 1;
  Result.Container := lcXz;
  Result.Check := lzCheckCrc64;
  Result.BufferSize := 2 shl 20;
  Result.Lc := -1;
  Result.Lp := -1;
  Result.Pb := -1;
  Result.FastBytes := 0;
  Result.CutValue := 0;
  Result.MemoryLimit := 0;
  Result.StrictValidation := False;
  Result.DecodeDiagnostics := nil;
  Result.ParserMode := lpmSdkProfile;
  Result.MatchFinderProfile := lmfpAuto;
  Result.XzBlockSize := 0;
  Result.ArchiveFileName := '';
  Result.EncodeDiagnostics := nil;
  Result.LzmaEndMarker := False;
end;

class function TLzma2.DefaultOptionsFor(const Container: TLzma2Container; const Level: TLzma2CompressionLevel;
  const ThreadCount: Integer): TLzma2Options;
begin
  Result := DefaultOptions;
  Result.Container := Container;
  Result.Level := Level;
  Result.DictionarySize := DefaultDictionaryForLevel(Level);
  Result.ThreadCount := ThreadCount;

  case Container of
    lcRawLzma2, lcLzma:
      Result.Check := lzCheckNone;
  else
    Result.Check := lzCheckCrc64;
  end;
end;

class function TLzma2.XzOptions(const Level: TLzma2CompressionLevel; const ThreadCount: Integer;
  const Check: TLzma2Check): TLzma2Options;
begin
  Result := DefaultOptionsFor(lcXz, Level, ThreadCount);
  Result.Check := Check;
end;

class function TLzma2.RawLzma2Options(const Level: TLzma2CompressionLevel; const ThreadCount: Integer): TLzma2Options;
begin
  Result := DefaultOptionsFor(lcRawLzma2, Level, ThreadCount);
end;

class function TLzma2.StandaloneLzmaOptions(const Level: TLzma2CompressionLevel;
  const EndMarker: Boolean): TLzma2Options;
begin
  Result := DefaultOptionsFor(lcLzma, Level, 1);
  Result.LzmaEndMarker := EndMarker;
end;

class function TLzma2.SevenZipOptions(const ArchiveFileName: string; const Level: TLzma2CompressionLevel;
  const ThreadCount: Integer): TLzma2Options;
begin
  Result := DefaultOptionsFor(lc7z, Level, ThreadCount);
  Result.ArchiveFileName := ArchiveFileName;
end;

class function TLzma2.FastOptionsFor(const Container: TLzma2Container; const ThreadCount: Integer): TLzma2Options;
begin
  Result := DefaultOptionsFor(Container, 1, ThreadCount);
end;

class function TLzma2.MaxOptionsFor(const Container: TLzma2Container; const ThreadCount: Integer): TLzma2Options;
begin
  Result := DefaultOptionsFor(Container, 9, ThreadCount);
end;

class procedure TLzma2.Compress(Source: TStream; Destination: TStream; const Options: TLzma2Options;
  const Progress: TLzma2ProgressEvent);
begin
  case Options.Container of
    lcRawLzma2:
      TLzma2Encoder.EncodeRaw(Source, Destination, Options, Progress);
    lcLzma:
      TLzmaStandalone.Encode(Source, Destination, Options, Progress);
    lcXz:
      TLzmaXz.Encode(Source, Destination, Options, Progress);
    lc7z:
      TLzma7z.Encode(Source, Destination, Options, Progress);
  else
    RaiseLzmaError(SZ_ERROR_PARAM, 'Unsupported LZMA2 container');
  end;
end;

class procedure TLzma2.Decompress(Source: TStream; Destination: TStream; const Options: TLzma2Options;
  const Progress: TLzma2ProgressEvent);
begin
  case Options.Container of
    lcRawLzma2:
      TLzma2Decoder.DecodeRaw(Source, Destination, Options, Progress);
    lcLzma:
      TLzmaStandalone.Decode(Source, Destination, Options, Progress);
    lcXz:
      TLzmaXz.Decode(Source, Destination, Options, Progress);
    lc7z:
      TLzma7z.Decode(Source, Destination, Options, Progress);
  else
    RaiseLzmaError(SZ_ERROR_PARAM, 'Unsupported LZMA2 container');
  end;
end;

class procedure TLzma2.CompressFile(const SourceFileName, DestinationFileName: string;
  const Options: TLzma2Options; const Progress: TLzma2ProgressEvent);
var
  Destination: TFileStream;
  Source: TFileStream;
  WorkOptions: TLzma2Options;
begin
  if SourceFileName = '' then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Source file name is empty');
  if DestinationFileName = '' then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Destination file name is empty');
  if not FileExists(SourceFileName) then
    RaiseLzmaError(SZ_ERROR_READ, 'Source file not found: ' + SourceFileName);

  WorkOptions := Options;
  if (WorkOptions.Container = lc7z) and (WorkOptions.ArchiveFileName = '') then
    WorkOptions.ArchiveFileName := ExtractFileName(SourceFileName);

  Source := TFileStream.Create(SourceFileName, fmOpenRead or fmShareDenyWrite);
  try
    Destination := TFileStream.Create(DestinationFileName, fmCreate);
    try
      Compress(Source, Destination, WorkOptions, Progress);
    finally
      Destination.Free;
    end;
  finally
    Source.Free;
  end;
end;

class procedure TLzma2.DecompressFile(const SourceFileName, DestinationFileName: string;
  const Options: TLzma2Options; const Progress: TLzma2ProgressEvent);
var
  Destination: TFileStream;
  Source: TFileStream;
begin
  if SourceFileName = '' then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Source file name is empty');
  if DestinationFileName = '' then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Destination file name is empty');
  if not FileExists(SourceFileName) then
    RaiseLzmaError(SZ_ERROR_READ, 'Source file not found: ' + SourceFileName);

  Source := TFileStream.Create(SourceFileName, fmOpenRead or fmShareDenyWrite);
  try
    Destination := TFileStream.Create(DestinationFileName, fmCreate);
    try
      Decompress(Source, Destination, Options, Progress);
    finally
      Destination.Free;
    end;
  finally
    Source.Free;
  end;
end;

class function TLzma2.CompressAsync(Source: TStream; Destination: TStream; const Options: TLzma2Options;
  const Progress: TLzma2ProgressEvent): ITask;
var
  TaskSource: TStream;
  TaskDestination: TStream;
  TaskOptions: TLzma2Options;
  TaskProgress: TLzma2ProgressEvent;
begin
  if Source = nil then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Source stream is nil');
  if Destination = nil then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Destination stream is nil');

  TaskSource := Source;
  TaskDestination := Destination;
  TaskOptions := Options;
  TaskProgress := Progress;
  Result := TTask.Run(
    procedure
    begin
      Compress(TaskSource, TaskDestination, TaskOptions, TaskProgress);
    end);
end;

class function TLzma2.DecompressAsync(Source: TStream; Destination: TStream; const Options: TLzma2Options;
  const Progress: TLzma2ProgressEvent): ITask;
var
  TaskSource: TStream;
  TaskDestination: TStream;
  TaskOptions: TLzma2Options;
  TaskProgress: TLzma2ProgressEvent;
begin
  if Source = nil then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Source stream is nil');
  if Destination = nil then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Destination stream is nil');

  TaskSource := Source;
  TaskDestination := Destination;
  TaskOptions := Options;
  TaskProgress := Progress;
  Result := TTask.Run(
    procedure
    begin
      Decompress(TaskSource, TaskDestination, TaskOptions, TaskProgress);
    end);
end;

end.
