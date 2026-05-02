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
    class procedure Compress(Source: TStream; Destination: TStream; const Options: TLzma2Options;
      const Progress: TLzma2ProgressEvent = nil); static;
    class procedure Decompress(Source: TStream; Destination: TStream; const Options: TLzma2Options;
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
