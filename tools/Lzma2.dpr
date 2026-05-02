program Lzma2;

{$APPTYPE CONSOLE}

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  System.Diagnostics,
  System.Generics.Collections,
  System.IOUtils,
  System.StrUtils,
  System.SyncObjs,
  System.Types,
  Lzma.Api in '..\src\Lzma.Api.pas',
  Lzma.Alloc in '..\src\Lzma.Alloc.pas',
  Lzma.Decoder in '..\src\Lzma.Decoder.pas',
  Lzma.Encoder in '..\src\Lzma.Encoder.pas',
  Lzma.Errors in '..\src\Lzma.Errors.pas',
  Lzma.Lzma in '..\src\Lzma.Lzma.pas',
  Lzma.MatchFinder in '..\src\Lzma.MatchFinder.pas',
  Lzma.MtDec in '..\src\Lzma.MtDec.pas',
  Lzma.RangeCoder in '..\src\Lzma.RangeCoder.pas',
  Lzma.SevenZip in '..\src\Lzma.SevenZip.pas',
  Lzma.Streams in '..\src\Lzma.Streams.pas',
  Lzma.Types in '..\src\Lzma.Types.pas',
  Lzma.Xz in '..\src\Lzma.Xz.pas',
  Lzma.XzCrc in '..\src\Lzma.XzCrc.pas',
  Lzma2.Decoder in '..\src\Lzma2.Decoder.pas',
  Lzma2.Encoder in '..\src\Lzma2.Encoder.pas',
  Lzma.CliPaths in '..\src\Lzma.CliPaths.pas';

const
  CLI_VERSION = '26.01';
  CLI_SDK_BASELINE = '7-Zip/LZMA SDK 26.01';
  CLI_CANCEL_EXIT_CODE = 3;

type
  TLzmaCliCommand = (ccCompress, ccExtract, ccTest);
  TLzmaCliPathMode = (pmReplace, pmDirect, pmConcat);

  TLzmaCli = record
    Command: TLzmaCliCommand;
    InputPath: string;
    InputPaths: TArray<string>;
    OutputPath: string;
    OutputDirectory: string;
    HasOutputDirectory: Boolean;
    PathMode: TLzmaCliPathMode;
    PreserveArchivePaths: Boolean;
    SevenZipMethod: TLzma7zEncodeMethod;
    ShowProgress: Boolean;
    ExplicitOutput: Boolean;
    Options: TLzma2Options;
  end;

  TLzmaBenchmarkOptions = record
    InputPath: string;
    StartLevel: Integer;
    EndLevel: Integer;
    Threads: Integer;
    DecompressThreads: Integer;
    Iterations: Integer;
    Seconds: Double;
    DictionarySize: UInt64;
    Container: TLzma2Container;
    Check: TLzma2Check;
  end;

  TLzmaBenchmarkMeasurement = record
    Compressed: TBytes;
    ElapsedTicks: Int64;
    Iterations: Integer;
  end;

  TNullWriteStream = class(TStream)
  private
    FSize: Int64;
    FPosition: Int64;
  protected
    function GetSize: Int64; override;
  public
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;

  TCountingWriteStream = class(TStream)
  private
    FBase: TStream;
    FCounter: PUInt64;
    FOwnsBase: Boolean;
  protected
    function GetSize: Int64; override;
  public
    constructor Create(const Base: TStream; const Counter: PUInt64; const OwnsBase: Boolean);
    destructor Destroy; override;
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;

  TSizeOnlyStream = class(TStream)
  private
    FSize: Int64;
    FPosition: Int64;
  protected
    function GetSize: Int64; override;
  public
    constructor Create(const Size: UInt64);
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;

var
  GCancelRequested: Integer = 0;

procedure Usage;
begin
  Writeln('Lzma2 native Delphi compression tool');
  Writeln;
  Writeln('Usage:');
  Writeln('  Lzma2 a <archive> <file|dir> [more files|dirs...] [switches]');
  Writeln('  Lzma2 x <archive> [output-file] [-o{dir}] [switches]');
  Writeln('  Lzma2 t <archive> [switches]');
  Writeln('  Lzma2 benchmark <input-file> [switches]');
  Writeln('  Lzma2 --help');
  Writeln('  Lzma2 --version');
  Writeln;
  Writeln('Common 7-Zip-style switches:');
  Writeln('  -txz | -tlzma | -t7z | -traw   Container type; xz is default');
  Writeln('  -mx=N | -mxN          Compression level 0..9');
  Writeln('  -md=SIZE | -mdSIZE    Dictionary size, for example 1m, 64m, 4g');
  Writeln('  -mmt=N | -mmtN        Thread count; on/all uses all logical CPUs');
  Writeln('  -m0=LZMA2|LZMA[:d=SIZE][:mt=N][:fb=N][:mc=N][:mf=hc4|hc5|bt4]');
  Writeln('  -mcheck=crc64         XZ check: none, crc32, crc64, sha256');
  Writeln('  -scrcCRC64            Alias for XZ check selection');
  Writeln('  -ms=SIZE | -msSIZE    XZ block size for independent blocks');
  Writeln('  -o{dir}               Output directory for x/e commands');
  Writeln('  -spod|-spoc|-spor     Output-path mode for -o');
  Writeln('  --progress            Print progress lines during the operation');
  Writeln;
  Writeln('Benchmark switches:');
  Writeln('  -T2                   Compression threads; default 2');
  Writeln('  -D2                   Decompression threads; default matches -T');
  Writeln('  -1 -e9                Start and end level; default 1..9');
  Writeln('  -i2                   Minimum iterations per level; default 2');
  Writeln('  -t3                   Minimum seconds per level; default 0');
  Writeln('  -traw | -txz          Container for the benchmark stream; raw is default');
  Writeln('  -md=SIZE              Fixed dictionary for every level; default is level-based');
  Writeln('  Benchmark CSV: codec,inputName,inputBytes,level,threads,decompressThreads,dictionaryBytes,container,compressedBytes,ratio,compressionMBps,decompressionMBps,compressElapsedMs,decompressElapsedMs,compressIterations,decompressIterations');
  Writeln('  Benchmark ratio=inputBytes/compressedBytes, matching fast-lzma2 bench.c.');
  Writeln;
  Writeln('Exit codes: 0 success, 1 command line error, 2 operation error, 3 cancelled.');
  Writeln;
  Writeln('Compatibility form:');
  Writeln('  Lzma2 compress|decompress input output [raw|lzma|xz|7z] [level] [dict] [threads] [none|crc32|crc64|sha256] [xzBlockSize]');
end;

procedure PrintVersion;
begin
  Writeln('Lzma2 native Delphi CLI ', CLI_VERSION);
  Writeln('SDK baseline: ', CLI_SDK_BASELINE);
  Writeln('Supported containers: raw LZMA2 (.lzma2), standalone LZMA (.lzma), XZ (.xz), 7z (.7z)');
  Writeln('Runtime: native Delphi only; no external DLL/OBJ/LIB/process compressor calls.');
end;

function ConsoleCtrlHandler(CtrlType: DWORD): BOOL; stdcall;
begin
  case CtrlType of
    CTRL_C_EVENT,
    CTRL_BREAK_EVENT:
      begin
        TInterlocked.Exchange(GCancelRequested, 1);
        Result := True;
      end;
  else
    Result := False;
  end;
end;

function TNullWriteStream.GetSize: Int64;
begin
  Result := FSize;
end;

function TNullWriteStream.Read(var Buffer; Count: Longint): Longint;
begin
  Result := 0;
end;

function TNullWriteStream.Write(const Buffer; Count: Longint): Longint;
begin
  if Count <= 0 then
    Exit(0);
  Inc(FPosition, Count);
  if FPosition > FSize then
    FSize := FPosition;
  Result := Count;
end;

function TNullWriteStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  case Origin of
    soBeginning:
      FPosition := Offset;
    soCurrent:
      Inc(FPosition, Offset);
    soEnd:
      FPosition := FSize + Offset;
  end;
  if FPosition < 0 then
    raise EArgumentOutOfRangeException.Create('Negative null stream position');
  Result := FPosition;
end;

constructor TCountingWriteStream.Create(const Base: TStream; const Counter: PUInt64; const OwnsBase: Boolean);
begin
  inherited Create;
  FBase := Base;
  FCounter := Counter;
  FOwnsBase := OwnsBase;
end;

destructor TCountingWriteStream.Destroy;
begin
  if FOwnsBase then
    FBase.Free;
  inherited;
end;

function TCountingWriteStream.GetSize: Int64;
begin
  Result := FBase.Size;
end;

function TCountingWriteStream.Read(var Buffer; Count: Longint): Longint;
begin
  Result := FBase.Read(Buffer, Count);
end;

function TCountingWriteStream.Write(const Buffer; Count: Longint): Longint;
begin
  Result := FBase.Write(Buffer, Count);
  if (Result > 0) and (FCounter <> nil) then
    Inc(FCounter^, UInt64(Result));
end;

function TCountingWriteStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  Result := FBase.Seek(Offset, Origin);
end;

constructor TSizeOnlyStream.Create(const Size: UInt64);
begin
  inherited Create;
  if Size > UInt64(High(Int64)) then
    FSize := High(Int64)
  else
    FSize := Int64(Size);
end;

function TSizeOnlyStream.GetSize: Int64;
begin
  Result := FSize;
end;

function TSizeOnlyStream.Read(var Buffer; Count: Longint): Longint;
begin
  Result := 0;
end;

function TSizeOnlyStream.Write(const Buffer; Count: Longint): Longint;
begin
  raise EWriteError.Create('size-only stream is read-only');
end;

function TSizeOnlyStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  case Origin of
    soBeginning:
      FPosition := Offset;
    soCurrent:
      Inc(FPosition, Offset);
    soEnd:
      FPosition := FSize + Offset;
  end;
  if FPosition < 0 then
    raise EArgumentOutOfRangeException.Create('Negative size-only stream position');
  Result := FPosition;
end;

procedure FailUsage(const Message: string);
begin
  Writeln('Command line error: ', Message);
  Writeln;
  Usage;
  Halt(1);
end;

function RequireValue(const Value, Name: string): string;
begin
  Result := Trim(Value);
  if Result = '' then
    FailUsage(Name + ' requires a value');
end;

function ParseContainer(const S: string): TLzma2Container;
begin
  if SameText(S, 'raw') or SameText(S, 'lzma2') then
    Result := lcRawLzma2
  else if SameText(S, 'lzma') or SameText(S, 'alone') then
    Result := lcLzma
  else if SameText(S, 'xz') then
    Result := lcXz
  else if SameText(S, '7z') then
    Result := lc7z
  else
  begin
    FailUsage('unsupported container type: ' + S);
    Result := lcXz;
  end;
end;

function ParseCheck(const S: string): TLzma2Check;
begin
  if SameText(S, 'none') or SameText(S, 'no') then
    Result := lzCheckNone
  else if SameText(S, 'crc32') then
    Result := lzCheckCrc32
  else if SameText(S, 'crc64') then
    Result := lzCheckCrc64
  else if SameText(S, 'sha256') or SameText(S, 'sha-256') then
    Result := lzCheckSha256
  else
  begin
    FailUsage('unsupported XZ check: ' + S);
    Result := lzCheckCrc64;
  end;
end;

function ParseLevel(const S: string): Integer;
begin
  Result := StrToInt(RequireValue(S, 'compression level'));
  if (Result < 0) or (Result > 9) then
    FailUsage('compression level must be in 0..9');
end;

function ParseSize(const S: string): UInt64;
var
  Text: string;
  Suffix: Char;
  Multiplier: UInt64;
begin
  Text := Trim(S);
  if Text = '' then
    FailUsage('size value is empty');

  Multiplier := 1;
  Suffix := UpCase(Text[Length(Text)]);
  case Suffix of
    'B':
      Delete(Text, Length(Text), 1);
    'K':
      begin
        Multiplier := UInt64(1) shl 10;
        Delete(Text, Length(Text), 1);
      end;
    'M':
      begin
        Multiplier := UInt64(1) shl 20;
        Delete(Text, Length(Text), 1);
      end;
    'G':
      begin
        Multiplier := UInt64(1) shl 30;
        Delete(Text, Length(Text), 1);
      end;
  end;

  Text := Trim(Text);
  if Text = '' then
    FailUsage('size value is empty');
  Result := StrToUInt64(Text) * Multiplier;
end;

function ParseThreads(const S: string): Integer;
var
  Text: string;
begin
  Text := RequireValue(S, 'thread count');
  if SameText(Text, 'on') or SameText(Text, 'all') then
    Result := TThread.ProcessorCount
  else if SameText(Text, 'off') then
    Result := 1
  else
    Result := StrToInt(Text);
  if Result < 1 then
    FailUsage('thread count must be positive');
end;

function ParseBenchmarkSeconds(const S: string): Double;
var
  Text: string;
begin
  Text := StringReplace(RequireValue(S, 'benchmark seconds'), '.', FormatSettings.DecimalSeparator, []);
  Result := StrToFloat(Text);
  if Result < 0 then
    FailUsage('benchmark seconds must not be negative');
end;

function ParseFastBytes(const S: string): Integer;
begin
  Result := StrToInt(RequireValue(S, 'fast bytes'));
  if (Result < LZMA_FAST_BYTES_MIN) or (Result > LZMA_FAST_BYTES_MAX) then
    FailUsage(Format('fast bytes must be in %d..%d', [LZMA_FAST_BYTES_MIN, LZMA_FAST_BYTES_MAX]));
end;

function ParseCutValue(const S: string): UInt32;
var
  Value: UInt64;
begin
  Value := StrToUInt64(RequireValue(S, 'match finder cycles'));
  if Value = 0 then
    FailUsage('match finder cycles must be positive');
  if Value > UInt64($FFFFFFFF) then
    FailUsage('match finder cycles must fit in UInt32');
  Result := UInt32(Value);
end;

function ParseMatchFinderProfile(const S: string): TLzmaMatchFinderProfile;
var
  Text: string;
begin
  Text := RequireValue(S, 'match finder profile');
  if SameText(Text, 'hc4') then
    Result := lmfpHashChain4
  else if SameText(Text, 'hc5') then
    Result := lmfpHashChain5
  else if SameText(Text, 'bt4') then
    Result := lmfpBinaryTree4
  else
  begin
    FailUsage('supported LZMA2 match finders: hc4, hc5, bt4');
    Result := lmfpAuto;
  end;
end;

function IsSwitch(const S: string): Boolean;
begin
  Result := (S <> '') and ((S[1] = '-') or (S[1] = '/'));
end;

function SwitchBody(const S: string): string;
begin
  Result := S;
  while (Result <> '') and ((Result[1] = '-') or (Result[1] = '/')) do
    Delete(Result, 1, 1);
end;

function ValueAfterEqualsOrPrefix(const Body, Prefix: string): string;
begin
  if StartsText(Prefix + '=', Body) then
    Result := Copy(Body, Length(Prefix) + 2, MaxInt)
  else
    Result := Copy(Body, Length(Prefix) + 1, MaxInt);
end;

procedure ApplyMethodOptions(var Cli: TLzmaCli; const MethodText: string);
var
  Text: string;
  Part: string;
  EqPos: Integer;
  Name: string;
  Value: string;
  SepPos: Integer;
begin
  Text := MethodText;
  SepPos := Pos(':', Text);
  if SepPos = 0 then
  begin
    Part := Text;
    Text := '';
  end
  else
  begin
    Part := Copy(Text, 1, SepPos - 1);
    Delete(Text, 1, SepPos);
  end;

  if SameText(Part, 'LZMA2') then
    Cli.SevenZipMethod := zemLzma2
  else if SameText(Part, 'LZMA') then
    Cli.SevenZipMethod := zemLzma
  else
    FailUsage('only LZMA and LZMA2 methods are supported');

  while Text <> '' do
  begin
    SepPos := Pos(':', Text);
    if SepPos = 0 then
    begin
      Part := Text;
      Text := '';
    end
    else
    begin
      Part := Copy(Text, 1, SepPos - 1);
      Delete(Text, 1, SepPos);
    end;

    if Part = '' then
      Continue;

    EqPos := Pos('=', Part);
    if EqPos = 0 then
      FailUsage('unsupported LZMA2 method option: ' + Part);

    Name := Copy(Part, 1, EqPos - 1);
    Value := Copy(Part, EqPos + 1, MaxInt);
    if SameText(Name, 'd') or SameText(Name, 'dict') then
      Cli.Options.DictionarySize := ParseSize(Value)
    else if SameText(Name, 'mt') or SameText(Name, 'mmt') then
      Cli.Options.ThreadCount := ParseThreads(Value)
    else if SameText(Name, 'fb') then
      Cli.Options.FastBytes := ParseFastBytes(Value)
    else if SameText(Name, 'mc') then
      Cli.Options.CutValue := ParseCutValue(Value)
    else if SameText(Name, 'mf') then
      Cli.Options.MatchFinderProfile := ParseMatchFinderProfile(Value)
    else if SameText(Name, 'lc') then
      Cli.Options.Lc := StrToInt(RequireValue(Value, 'literal context bits'))
    else if SameText(Name, 'lp') then
      Cli.Options.Lp := StrToInt(RequireValue(Value, 'literal position bits'))
    else if SameText(Name, 'pb') then
      Cli.Options.Pb := StrToInt(RequireValue(Value, 'position bits'))
    else if SameText(Name, 'a') then
      FailUsage('LZMA method algorithm option is not supported by this native release: ' + Name)
    else
      FailUsage('unsupported LZMA method option: ' + Name);
  end;
end;

procedure ApplySwitch(var Cli: TLzmaCli; const Switch: string);
var
  Body: string;
  LowerBody: string;
  MethodText: string;
begin
  Body := SwitchBody(Switch);
  LowerBody := AnsiLowerCase(Body);
  if LowerBody = '' then
    FailUsage('empty switch');

  if StartsText('t', Body) and (Length(Body) > 1) then
  begin
    Cli.Options.Container := ParseContainer(Copy(Body, 2, MaxInt));
    Exit;
  end;

  if StartsText('mx', Body) and (Length(Body) > 2) then
  begin
    Cli.Options.Level := ParseLevel(ValueAfterEqualsOrPrefix(Body, 'mx'));
    if Cli.Options.DictionarySize = 0 then
      Cli.Options.DictionarySize := DefaultDictionaryForLevel(Cli.Options.Level);
    Exit;
  end;

  if StartsText('md', Body) and (Length(Body) > 2) then
  begin
    Cli.Options.DictionarySize := ParseSize(ValueAfterEqualsOrPrefix(Body, 'md'));
    Exit;
  end;

  if StartsText('mmt', Body) and (Length(Body) > 3) then
  begin
    Cli.Options.ThreadCount := ParseThreads(ValueAfterEqualsOrPrefix(Body, 'mmt'));
    Exit;
  end;

  if StartsText('mcheck', Body) then
  begin
    Cli.Options.Check := ParseCheck(ValueAfterEqualsOrPrefix(Body, 'mcheck'));
    Exit;
  end;

  if StartsText('scrc', Body) then
  begin
    Cli.Options.Check := ParseCheck(Copy(Body, 5, MaxInt));
    Exit;
  end;

  if StartsText('ms', Body) and (Length(Body) > 2) then
  begin
    Cli.Options.XzBlockSize := ParseSize(ValueAfterEqualsOrPrefix(Body, 'ms'));
    Exit;
  end;

  if StartsText('m0=', LowerBody) then
  begin
    MethodText := Copy(Body, 4, MaxInt);
    ApplyMethodOptions(Cli, MethodText);
    Exit;
  end;

  if StartsText('o', Body) and (Length(Body) > 1) then
  begin
    Cli.OutputDirectory := Copy(SwitchBody(Switch), 2, MaxInt);
    Cli.HasOutputDirectory := True;
    Exit;
  end;

  if SameText(Body, 'spod') then
  begin
    Cli.PathMode := pmDirect;
    Exit;
  end;

  if SameText(Body, 'spoc') then
  begin
    Cli.PathMode := pmConcat;
    Exit;
  end;

  if SameText(Body, 'spor') then
  begin
    Cli.PathMode := pmReplace;
    Exit;
  end;

  if SameText(Body, 'progress') then
  begin
    Cli.ShowProgress := True;
    Exit;
  end;

  if SameText(Body, 'no-progress') then
  begin
    Cli.ShowProgress := False;
    Exit;
  end;

  FailUsage('unsupported switch: ' + Switch);
end;

function ExtensionForContainer(const Container: TLzma2Container): string;
begin
  case Container of
    lcRawLzma2:
      Result := '.lzma2';
    lcLzma:
      Result := '.lzma';
    lc7z:
      Result := '.7z';
  else
    Result := '.xz';
  end;
end;

procedure ResolveArchiveDefaultOutput(var Cli: TLzmaCli);
var
  Input: TFileStream;
  StoredName: string;
begin
  if (Cli.Command <> ccExtract) or Cli.ExplicitOutput then
    Exit;
  if Cli.Options.Container <> lc7z then
    Exit;

  Input := TFileStream.Create(Cli.InputPath, fmOpenRead or fmShareDenyWrite);
  try
    StoredName := TLzma7z.ReadSingleFileName(Input);
  finally
    Input.Free;
  end;

  Cli.OutputPath := TPath.Combine(ExtractFileDir(Cli.InputPath),
    SafeStoredOutputName(StoredName, DefaultExtractPath(Cli.InputPath, Cli.Options.Container)));
end;

procedure ApplyOutputDirectory(var Cli: TLzmaCli; const ExplicitOutput: Boolean);
var
  Name: string;
begin
  if (Cli.Command = ccTest) or (not Cli.HasOutputDirectory) or ExplicitOutput then
    Exit;

  Name := ExtractFileName(Cli.OutputPath);
  case Cli.PathMode of
    pmConcat:
      Cli.OutputPath := Cli.OutputDirectory + Name;
  else
    Cli.OutputPath := TPath.Combine(Cli.OutputDirectory, Name);
  end;
end;

function ParseCompatibilityCli(var Cli: TLzmaCli): Boolean;
var
  Mode: string;
begin
  Result := False;
  if ParamCount < 3 then
    Exit;

  Mode := ParamStr(1);
  if SameText(Mode, 'compress') then
    Cli.Command := ccCompress
  else if SameText(Mode, 'decompress') then
    Cli.Command := ccExtract
  else
    Exit;

  Cli.Options := TLzma2.DefaultOptions;
  Cli.InputPath := ParamStr(2);
  Cli.InputPaths := TArray<string>.Create(Cli.InputPath);
  Cli.OutputPath := ParamStr(3);
  Cli.ExplicitOutput := True;
  Cli.SevenZipMethod := zemLzma2;
  if ParamCount >= 4 then
    Cli.Options.Container := ParseContainer(ParamStr(4));
  if ParamCount >= 5 then
    Cli.Options.Level := TLzma2CompressionLevel(ParseLevel(ParamStr(5)));
  if ParamCount >= 6 then
    Cli.Options.DictionarySize := StrToUInt64(ParamStr(6));
  if ParamCount >= 7 then
    Cli.Options.ThreadCount := ParseThreads(ParamStr(7));
  if ParamCount >= 8 then
    Cli.Options.Check := ParseCheck(ParamStr(8));
  if ParamCount >= 9 then
    Cli.Options.XzBlockSize := StrToUInt64(ParamStr(9));
  if Cli.Command = ccCompress then
    Cli.Options.ArchiveFileName := ExtractFileName(Cli.InputPath);
  Result := True;
end;

procedure AddCliInputPath(var Cli: TLzmaCli; const Path: string);
var
  OldLen: Integer;
begin
  OldLen := Length(Cli.InputPaths);
  SetLength(Cli.InputPaths, OldLen + 1);
  Cli.InputPaths[OldLen] := Path;
  if Cli.InputPath = '' then
    Cli.InputPath := Path;
end;

function ParseCli(var Cli: TLzmaCli): Boolean;
var
  CommandText: string;
  I: Integer;
  ExplicitOutput: Boolean;
begin
  Cli := Default(TLzmaCli);
  Cli.Options := TLzma2.DefaultOptions;
  Cli.PathMode := pmReplace;
  Cli.PreserveArchivePaths := True;
  Cli.SevenZipMethod := zemLzma2;
  ExplicitOutput := False;

  if ParseCompatibilityCli(Cli) then
    Exit(True);

  Result := False;
  if ParamCount < 1 then
    Exit;

  CommandText := ParamStr(1);
  if SameText(CommandText, 'a') then
  begin
    if ParamCount < 3 then
      FailUsage('a requires <archive> and at least one <file|dir>');
    Cli.Command := ccCompress;
    Cli.OutputPath := ParamStr(2);
    I := 3;
    while (I <= ParamCount) and not IsSwitch(ParamStr(I)) do
    begin
      AddCliInputPath(Cli, ParamStr(I));
      Inc(I);
    end;
    if Length(Cli.InputPaths) = 0 then
      FailUsage('a requires at least one <file|dir>');
    Cli.Options.ArchiveFileName := ExtractFileName(Cli.InputPath);
  end
  else if SameText(CommandText, 'x') or SameText(CommandText, 'e') then
  begin
    if ParamCount < 2 then
      FailUsage('x requires <archive>');
    Cli.Command := ccExtract;
    Cli.PreserveArchivePaths := SameText(CommandText, 'x');
    Cli.InputPath := ParamStr(2);
    I := 3;
    if (I <= ParamCount) and not IsSwitch(ParamStr(I)) then
    begin
      Cli.OutputPath := ParamStr(I);
      ExplicitOutput := True;
      Inc(I);
    end
    else
      Cli.OutputPath := DefaultExtractPath(Cli.InputPath, Cli.Options.Container);
  end
  else if SameText(CommandText, 't') then
  begin
    if ParamCount < 2 then
      FailUsage('t requires <archive>');
    Cli.Command := ccTest;
    Cli.InputPath := ParamStr(2);
    I := 3;
  end
  else
    Exit(False);

  while I <= ParamCount do
  begin
    if not IsSwitch(ParamStr(I)) then
      FailUsage('unexpected argument: ' + ParamStr(I));
    ApplySwitch(Cli, ParamStr(I));
    Inc(I);
  end;

  if (Cli.Command = ccExtract) and (not ExplicitOutput) then
    Cli.OutputPath := DefaultExtractPath(Cli.InputPath, Cli.Options.Container);
  Cli.ExplicitOutput := ExplicitOutput;

  if Cli.Command = ccCompress then
  begin
    if ExtractFileExt(Cli.OutputPath) = '' then
      Cli.OutputPath := Cli.OutputPath + ExtensionForContainer(Cli.Options.Container);
  end;

  Result := True;
end;

function IsHelpRequest: Boolean;
var
  Text: string;
begin
  if ParamCount <> 1 then
    Exit(False);
  Text := ParamStr(1);
  Result := SameText(Text, '--help') or SameText(Text, '-h') or SameText(Text, '/?') or
    SameText(Text, 'help');
end;

function IsVersionRequest: Boolean;
begin
  Result := (ParamCount = 1) and SameText(ParamStr(1), '--version');
end;

function IsBenchmarkRequest: Boolean;
begin
  Result := (ParamCount >= 1) and SameText(ParamStr(1), 'benchmark');
end;

function DecodeFallbackReasonName(const Reason: TLzma2DecodeFallbackReason): string;
begin
  case Reason of
    ldfrNone: Result := 'none';
    ldfrThreadCountOne: Result := 'thread-count-one';
    ldfrNonSeekableStream: Result := 'non-seekable-stream';
    ldfrSingleIndependentUnit: Result := 'single-independent-unit';
    ldfrUnknownPackedSize: Result := 'unknown-packed-size';
    ldfrUnknownUnpackedSize: Result := 'unknown-unpacked-size';
    ldfrUnsupportedLayout: Result := 'unsupported-layout';
    ldfrMemoryLimit: Result := 'memory-limit';
    ldfrInsufficientWork: Result := 'insufficient-work';
  else
    Result := 'unknown';
  end;
end;

function ParserModeName(const Mode: TLzmaParserMode): string;
begin
  case Mode of
    lpmSdkProfile: Result := 'sdk-profile';
    lpmFast: Result := 'fast';
    lpmHighSpeed: Result := 'high-speed';
  else
    Result := 'unknown';
  end;
end;

function MatchFinderProfileName(const Profile: TLzmaMatchFinderProfile): string;
begin
  case Profile of
    lmfpAuto: Result := 'auto';
    lmfpHashChain4: Result := 'hc4';
    lmfpHashChain5: Result := 'hc5';
    lmfpBinaryTree4: Result := 'bt4';
  else
    Result := 'unknown';
  end;
end;

procedure PrintStats(const Cli: TLzmaCli; const InputStream, OutputStream: TStream;
  const Watch: TStopwatch; const EncodeDiagnostics: TLzma2EncodeDiagnostics;
  const DecodeDiagnostics: TLzma2DecodeDiagnostics);
var
  InSize: UInt64;
  OutSize: UInt64;
  Throughput: Double;
begin
  InSize := InputStream.Size;
  OutSize := OutputStream.Size;
  Writeln('Input bytes: ', InSize);
  Writeln('Output bytes: ', OutSize);
  if (InSize <> 0) and (OutSize <> 0) then
    Writeln('Ratio (input/output): ', FormatFloat('0.000', InSize / OutSize))
  else if InSize <> 0 then
    Writeln('Ratio (input/output): n/a');
  Writeln('Elapsed ms: ', Watch.ElapsedMilliseconds);
  if Watch.ElapsedMilliseconds > 0 then
  begin
    Throughput := (InSize / 1048576.0) / (Watch.ElapsedMilliseconds / 1000.0);
    Writeln('Throughput MiB/s: ', FormatFloat('0.000', Throughput));
  end;
  if Cli.Command = ccCompress then
  begin
    Writeln('Encode requested threads: ', EncodeDiagnostics.RequestedThreadCount);
    Writeln('Encode actual threads: ', EncodeDiagnostics.ActualThreadCount);
    Writeln('Encode batches: ', EncodeDiagnostics.BatchCount);
    Writeln('Encode blocks: ', EncodeDiagnostics.BlockCount);
    Writeln('Encode fast bytes: ', EncodeDiagnostics.FastBytes);
    Writeln('Encode nice len: ', EncodeDiagnostics.NiceLen);
    Writeln('Encode cut value: ', EncodeDiagnostics.CutValue);
    Writeln('Encode XZ block size: ', EncodeDiagnostics.XzBlockSize);
    Writeln('Encode parser mode: ', ParserModeName(EncodeDiagnostics.ParserMode));
    Writeln('Encode match finder profile: ', MatchFinderProfileName(EncodeDiagnostics.MatchFinderProfile));
    Writeln('Encode num hash bytes: ', EncodeDiagnostics.NumHashBytes);
    Writeln('Encode copy fast paths: ', EncodeDiagnostics.CopyFastPathCount);
    Writeln('Encode incompressible fast paths: ', EncodeDiagnostics.IncompressibleFastPathCount);
    Writeln('Encode optimum parser enabled: ', BoolToStr(EncodeDiagnostics.OptimumParserEnabled, True));
    Writeln('Encode full optimum decisions: ', EncodeDiagnostics.FullOptimumDecisionCount);
    Writeln('Encode fallback: ', EncodeDiagnostics.FallbackReason);
  end;
  if Cli.Command <> ccCompress then
  begin
    Writeln('Decode requested threads: ', DecodeDiagnostics.RequestedThreadCount);
    Writeln('Decode actual threads: ', DecodeDiagnostics.ActualThreadCount);
    Writeln('Decode independent units: ', DecodeDiagnostics.IndependentUnitCount);
    Writeln('Decode used MT: ', BoolToStr(DecodeDiagnostics.UsedMultiThread, True));
    Writeln('Decode input snapshot: ', BoolToStr(DecodeDiagnostics.InputSnapshot, True));
    Writeln('Decode fallback: ', DecodeFallbackReasonName(DecodeDiagnostics.FallbackReason));
  end;
end;

function CreateProgressCallback(const Cli: TLzmaCli; const InputStream: TStream;
  const Watch: TStopwatch): TLzma2ProgressEvent;
var
  LastProgressTick: Int64;
  InputTotal: UInt64;
begin
  LastProgressTick := -1;
  try
    if InputStream.Size > 0 then
      InputTotal := UInt64(InputStream.Size)
    else
      InputTotal := 0;
  except
    InputTotal := 0;
  end;

  Result :=
    procedure(const InBytes: UInt64; const OutBytes: UInt64; var Cancel: Boolean)
    var
      NowMs: Int64;
      Percent: Double;
      Throughput: Double;
      PercentText: string;
    begin
      if TInterlocked.CompareExchange(GCancelRequested, 0, 0) <> 0 then
        Cancel := True;

      if not Cli.ShowProgress then
        Exit;

      NowMs := Watch.ElapsedMilliseconds;
      if (LastProgressTick >= 0) and (NowMs - LastProgressTick < 500) and (not Cancel) then
        Exit;
      LastProgressTick := NowMs;

      if InputTotal <> 0 then
      begin
        Percent := (InBytes * 100.0) / InputTotal;
        if Percent > 100.0 then
          Percent := 100.0;
        PercentText := FormatFloat('0.0', Percent) + '%'
      end
      else
        PercentText := 'n/a';

      if NowMs > 0 then
        Throughput := (InBytes / 1048576.0) / (NowMs / 1000.0)
      else
        Throughput := 0.0;

      Writeln('Progress: in=', InBytes, ' out=', OutBytes,
        ' percent=', PercentText, ' speedMiB=', FormatFloat('0.000', Throughput));
    end;
end;

function BuildTempOutputPath(const FinalPath: string): string;
var
  Dir: string;
  Name: string;
  Counter: Integer;
begin
  Dir := ExtractFileDir(FinalPath);
  if Dir = '' then
    Dir := GetCurrentDir;
  Name := ExtractFileName(FinalPath);
  Counter := 0;
  repeat
    Result := TPath.Combine(Dir, Format('%s.tmp.%d.%d', [Name, GetCurrentProcessId, Counter]));
    Inc(Counter);
  until not TFile.Exists(Result);
end;

procedure EnsureOutputDirectory(const OutputPath: string);
var
  Dir: string;
begin
  Dir := ExtractFileDir(OutputPath);
  if Dir <> '' then
    TDirectory.CreateDirectory(Dir);
end;

function CreateOutputStream(const Cli: TLzmaCli; out TempPath: string): TStream;
begin
  TempPath := '';
  if Cli.Command = ccTest then
    Exit(TNullWriteStream.Create);

  EnsureOutputDirectory(Cli.OutputPath);
  TempPath := BuildTempOutputPath(Cli.OutputPath);
  Result := TFileStream.Create(TempPath, fmCreate);
end;

procedure FinalizeOutputFile(const TempPath, FinalPath: string);
begin
  if TempPath = '' then
    Exit;
  if TFile.Exists(FinalPath) then
    TFile.Delete(FinalPath);
  TFile.Move(TempPath, FinalPath);
end;

procedure CleanupOutputFile(const TempPath: string);
begin
  try
    if (TempPath <> '') and TFile.Exists(TempPath) then
      TFile.Delete(TempPath);
  except
    // Preserve the original codec or cancellation exception.
  end;
end;

function SevenZipNeedsDirectoryExtraction(const Cli: TLzmaCli): Boolean;
var
  Input: TFileStream;
  Entries: TArray<TLzma7zEntry>;
begin
  Result := False;
  if (Cli.Command = ccCompress) or (Cli.Options.Container <> lc7z) then
    Exit;

  Input := TFileStream.Create(Cli.InputPath, fmOpenRead or fmShareDenyWrite);
  try
    Entries := TLzma7z.List(Input);
  finally
    Input.Free;
  end;
  Result := (Length(Entries) <> 1) or ((Length(Entries) = 1) and Entries[0].IsDirectory);
end;

function SevenZipDirectoryOutputRoot(const Cli: TLzmaCli): string;
begin
  if Cli.HasOutputDirectory then
    Result := Cli.OutputDirectory
  else
    Result := Cli.OutputPath;
  if Result = '' then
    Result := DefaultExtractPath(Cli.InputPath, Cli.Options.Container);
end;

procedure AddOwnedOutputStream(var Streams: TArray<TStream>; const Stream: TStream);
var
  OldLen: Integer;
begin
  OldLen := Length(Streams);
  SetLength(Streams, OldLen + 1);
  Streams[OldLen] := Stream;
end;

procedure RunSevenZipDirectoryExtraction(const Cli: TLzmaCli; const InputStream: TStream;
  const Options: TLzma2Options; const Progress: TLzma2ProgressEvent; out OutputBytes: UInt64);
var
  OutputRoot: string;
  OpenStreams: TArray<TStream>;
  I: Integer;
  OpenEntry: TLzma7zOpenEntryStream;
  Counter: UInt64;

begin
  if (Cli.Command <> ccTest) and Cli.ExplicitOutput then
    FailUsage('multi-file 7z extraction requires -o{dir} or no positional output');

  Counter := 0;
  OutputBytes := 0;
  SetLength(OpenStreams, 0);
  OutputRoot := SevenZipDirectoryOutputRoot(Cli);
  if Cli.Command <> ccTest then
    TDirectory.CreateDirectory(OutputRoot);
  OpenEntry :=
    function(const Entry: TLzma7zEntry): TStream
    var
      RelativePath: string;
      OutputPath: string;
      FileStream: TFileStream;
    begin
      if Cli.Command = ccTest then
      begin
        if Entry.IsDirectory then
          Exit(nil);
        Result := TCountingWriteStream.Create(TNullWriteStream.Create, @Counter, True);
        AddOwnedOutputStream(OpenStreams, Result);
        Exit;
      end;

      RelativePath := SafeStoredRelativePath(Entry.FileName, ExtractFileName(Cli.InputPath) + '.out',
        Cli.PreserveArchivePaths);
      OutputPath := TPath.Combine(OutputRoot, RelativePath);
      if Entry.IsDirectory then
      begin
        TDirectory.CreateDirectory(OutputPath);
        Exit(nil);
      end;

      EnsureOutputDirectory(OutputPath);
      FileStream := TFileStream.Create(OutputPath, fmCreate);
      Result := TCountingWriteStream.Create(FileStream, @Counter, True);
      AddOwnedOutputStream(OpenStreams, Result);
    end;
  try
    TLzma7z.ExtractAll(InputStream, OpenEntry, Options, Progress);
  finally
    for I := 0 to High(OpenStreams) do
      OpenStreams[I].Free;
  end;
  OutputBytes := Counter;
end;

function SevenZipNeedsArchiveEncode(const Cli: TLzmaCli): Boolean;
begin
  Result := (Cli.Command = ccCompress) and (Cli.Options.Container = lc7z) and
    ((Cli.SevenZipMethod <> zemLzma2) or (Length(Cli.InputPaths) <> 1) or
    ((Length(Cli.InputPaths) = 1) and TDirectory.Exists(Cli.InputPaths[0])));
end;

function ArchiveStoredPathFromFullPath(const BaseParent, Path: string): string;
var
  Base: string;
  Full: string;
begin
  Base := IncludeTrailingPathDelimiter(ExpandFileName(BaseParent));
  Full := ExpandFileName(Path);
  if StartsText(Base, Full) then
    Result := Copy(Full, Length(Base) + 1, MaxInt)
  else
    Result := ExtractFileName(ExcludeTrailingPathDelimiter(Full));
  if Result = '' then
    Result := ExtractFileName(ExcludeTrailingPathDelimiter(Full));
  Result := StringReplace(Result, '\', '/', [rfReplaceAll]);
end;

procedure EnsureUniqueArchiveEntryName(const Entries: TArray<TLzma7zEncodeEntry>; const Name: string);
var
  I: Integer;
begin
  for I := 0 to High(Entries) do
    if SameText(Entries[I].FileName, Name) then
      FailUsage('duplicate 7z archive entry name: ' + Name);
end;

procedure AddSevenZipEncodeEntry(var Entries: TArray<TLzma7zEncodeEntry>; var SourcePaths: TArray<string>;
  const StoredName, SourcePath: string; const IsDirectory: Boolean; var TotalInputBytes: UInt64);
var
  OldLen: Integer;
  FileSize: Int64;
begin
  EnsureUniqueArchiveEntryName(Entries, StoredName);
  OldLen := Length(Entries);
  SetLength(Entries, OldLen + 1);
  SetLength(SourcePaths, OldLen + 1);
  Entries[OldLen].FileName := StoredName;
  Entries[OldLen].IsDirectory := IsDirectory;
  Entries[OldLen].HasAttributes := True;
  if IsDirectory then
    Entries[OldLen].Attributes := $10
  else
    Entries[OldLen].Attributes := $20;
  SourcePaths[OldLen] := SourcePath;
  if not IsDirectory then
  begin
    FileSize := TFile.GetSize(SourcePath);
    if FileSize > 0 then
      Inc(TotalInputBytes, UInt64(FileSize));
  end;
end;

procedure CollectSevenZipEncodeEntries(const Cli: TLzmaCli; out Entries: TArray<TLzma7zEncodeEntry>;
  out SourcePaths: TArray<string>; out TotalInputBytes: UInt64);
var
  Input: string;
  FullInput: string;
  BaseParent: string;
  Dirs: TStringDynArray;
  Files: TStringDynArray;
  Path: string;
begin
  SetLength(Entries, 0);
  SetLength(SourcePaths, 0);
  TotalInputBytes := 0;
  for Input in Cli.InputPaths do
  begin
    FullInput := ExpandFileName(Input);
    if TDirectory.Exists(FullInput) then
    begin
      FullInput := ExcludeTrailingPathDelimiter(FullInput);
      BaseParent := ExtractFileDir(FullInput);
      AddSevenZipEncodeEntry(Entries, SourcePaths, ArchiveStoredPathFromFullPath(BaseParent, FullInput),
        FullInput, True, TotalInputBytes);

      Dirs := TDirectory.GetDirectories(FullInput, '*', TSearchOption.soAllDirectories);
      TArray.Sort<string>(Dirs);
      for Path in Dirs do
        AddSevenZipEncodeEntry(Entries, SourcePaths, ArchiveStoredPathFromFullPath(BaseParent, Path),
          Path, True, TotalInputBytes);

      Files := TDirectory.GetFiles(FullInput, '*', TSearchOption.soAllDirectories);
      TArray.Sort<string>(Files);
      for Path in Files do
        AddSevenZipEncodeEntry(Entries, SourcePaths, ArchiveStoredPathFromFullPath(BaseParent, Path),
          Path, False, TotalInputBytes);
    end
    else if TFile.Exists(FullInput) then
      AddSevenZipEncodeEntry(Entries, SourcePaths, ExtractFileName(FullInput), FullInput, False, TotalInputBytes)
    else
      FailUsage('input path does not exist: ' + Input);
  end;
  if Length(Entries) = 0 then
    FailUsage('7z archive encode requires at least one existing file or directory');
end;

procedure RunSevenZipArchiveEncode(const Cli: TLzmaCli; const Entries: TArray<TLzma7zEncodeEntry>;
  const SourcePaths: TArray<string>; const OutputStream: TStream; var Options: TLzma2Options;
  const Progress: TLzma2ProgressEvent);
begin
  TLzma7z.EncodeEntries(Entries,
    function(const Entry: TLzma7zEncodeEntry; const EntryIndex: Integer): TStream
    begin
      if Entry.IsDirectory then
        Exit(nil);
      Result := TFileStream.Create(SourcePaths[EntryIndex], fmOpenRead or fmShareDenyWrite);
    end,
    OutputStream, Options, Cli.SevenZipMethod, Progress);
end;

function CsvField(const Value: string): string;
begin
  Result := Value;
  if (Pos('"', Result) > 0) or (Pos(',', Result) > 0) or
     (Pos(#13, Result) > 0) or (Pos(#10, Result) > 0) then
    Result := '"' + StringReplace(Result, '"', '""', [rfReplaceAll]) + '"';
end;

function CsvFloat(const Value: Double; const MaxDecimals: Integer): string;
var
  Settings: TFormatSettings;
  FormatText: string;
begin
  Settings := TFormatSettings.Create('en-US');
  if MaxDecimals <= 0 then
    FormatText := '0'
  else
    FormatText := '0.' + StringOfChar('#', MaxDecimals);
  Result := FormatFloat(FormatText, Value, Settings);
  if Result = '-0' then
    Result := '0';
end;

function StopwatchTicksToMilliseconds(const Ticks: Int64): Double;
begin
  if TStopwatch.Frequency <= 0 then
    Exit(0);
  Result := (Ticks * 1000.0) / TStopwatch.Frequency;
end;

function BenchmarkMBps(const Bytes: UInt64; const ElapsedTicks: Int64; const Iterations: Integer): Double;
var
  AverageSeconds: Double;
begin
  if (Bytes = 0) or (ElapsedTicks <= 0) or (Iterations <= 0) or (TStopwatch.Frequency <= 0) then
    Exit(0);
  AverageSeconds := (ElapsedTicks / TStopwatch.Frequency) / Iterations;
  if AverageSeconds <= 0 then
    Exit(0);
  Result := (Bytes / 1000000.0) / AverageSeconds;
end;

function BytesFromMemoryStream(const Stream: TMemoryStream): TBytes;
begin
  SetLength(Result, Stream.Size);
  if Stream.Size > 0 then
  begin
    Stream.Position := 0;
    Stream.ReadBuffer(Result[0], Stream.Size);
  end;
end;

function BytesEqual(const Left, Right: TBytes): Boolean;
begin
  if Length(Left) <> Length(Right) then
    Exit(False);
  if Length(Left) = 0 then
    Exit(True);
  Result := CompareMem(@Left[0], @Right[0], Length(Left));
end;

function BenchmarkContainerName(const Container: TLzma2Container): string;
begin
  case Container of
    lcRawLzma2:
      Result := 'raw';
    lcLzma:
      Result := 'lzma';
    lc7z:
      Result := '7z';
  else
    Result := 'xz';
  end;
end;

procedure ParseBenchmarkCli(var Benchmark: TLzmaBenchmarkOptions);
var
  I: Integer;
  Body: string;
  Level: Integer;
  Value: string;
begin
  if ParamCount < 2 then
    FailUsage('benchmark requires <input-file>');

  Benchmark := Default(TLzmaBenchmarkOptions);
  Benchmark.InputPath := ParamStr(2);
  Benchmark.StartLevel := 1;
  Benchmark.EndLevel := 9;
  Benchmark.Threads := 2;
  Benchmark.DecompressThreads := 0;
  Benchmark.Iterations := 2;
  Benchmark.Seconds := 0;
  Benchmark.DictionarySize := 0;
  Benchmark.Container := lcRawLzma2;
  Benchmark.Check := lzCheckNone;

  I := 3;
  while I <= ParamCount do
  begin
    if not IsSwitch(ParamStr(I)) then
      FailUsage('unexpected benchmark argument: ' + ParamStr(I));

    Body := SwitchBody(ParamStr(I));
    if Body = '' then
      FailUsage('empty benchmark switch');

    if (Length(Body) = 1) and CharInSet(Body[1], ['0'..'9']) then
    begin
      Level := StrToInt(Body);
      if (Level < 0) or (Level > 9) then
        FailUsage('benchmark start level must be in 0..9');
      Benchmark.StartLevel := Level;
    end
    else if (Body[1] = 'T') and (Length(Body) > 1) then
      Benchmark.Threads := ParseThreads(Copy(Body, 2, MaxInt))
    else if (Body[1] = 'D') and (Length(Body) > 1) then
      Benchmark.DecompressThreads := ParseThreads(Copy(Body, 2, MaxInt))
    else if SameText(Copy(Body, 1, 1), 'e') and (Length(Body) > 1) then
      Benchmark.EndLevel := ParseLevel(ValueAfterEqualsOrPrefix(Body, 'e'))
    else if SameText(Copy(Body, 1, 1), 'i') and (Length(Body) > 1) then
    begin
      Benchmark.Iterations := StrToInt(ValueAfterEqualsOrPrefix(Body, 'i'));
      if Benchmark.Iterations < 1 then
        FailUsage('benchmark iterations must be positive');
    end
    else if SameText(Copy(Body, 1, 2), 'md') and (Length(Body) > 2) then
      Benchmark.DictionarySize := ParseSize(ValueAfterEqualsOrPrefix(Body, 'md'))
    else if StartsText('mmt', Body) and (Length(Body) > 3) then
      Benchmark.Threads := ParseThreads(ValueAfterEqualsOrPrefix(Body, 'mmt'))
    else if SameText(Copy(Body, 1, 6), 'mcheck') then
      Benchmark.Check := ParseCheck(ValueAfterEqualsOrPrefix(Body, 'mcheck'))
    else if SameText(Copy(Body, 1, 4), 'scrc') then
      Benchmark.Check := ParseCheck(Copy(Body, 5, MaxInt))
    else if SameText(Copy(Body, 1, 1), 't') and (Length(Body) > 1) then
    begin
      Value := Copy(Body, 2, MaxInt);
      if CharInSet(Value[1], ['0'..'9', '.', ',']) then
        Benchmark.Seconds := ParseBenchmarkSeconds(Value)
      else
        Benchmark.Container := ParseContainer(Value);
    end
    else
      FailUsage('unsupported benchmark switch: ' + ParamStr(I));

    Inc(I);
  end;

  if Benchmark.DecompressThreads = 0 then
    Benchmark.DecompressThreads := Benchmark.Threads;
  if Benchmark.StartLevel > Benchmark.EndLevel then
    FailUsage('benchmark start level must not exceed end level');
  if Benchmark.Container in [lcXz, lc7z] then
  begin
    if Benchmark.Check = lzCheckNone then
      Benchmark.Check := lzCheckCrc32;
  end
  else
    Benchmark.Check := lzCheckNone;
end;

function RunBenchmarkCompress(const Source: TBytes; const Options: TLzma2Options;
  const MinIterations: Integer; const MinTicks: Int64): TLzmaBenchmarkMeasurement;
var
  SourceStream: TBytesStream;
  OutputStream: TMemoryStream;
  Watch: TStopwatch;
begin
  Result := Default(TLzmaBenchmarkMeasurement);
  SourceStream := TBytesStream.Create(Source);
  OutputStream := TMemoryStream.Create;
  try
    Watch := TStopwatch.StartNew;
    repeat
      SourceStream.Position := 0;
      OutputStream.Clear;
      TLzma2.Compress(SourceStream, OutputStream, Options);
      Inc(Result.Iterations);
    until (Result.Iterations >= MinIterations) and (Watch.ElapsedTicks >= MinTicks);
    Watch.Stop;
    Result.ElapsedTicks := Watch.ElapsedTicks;
    Result.Compressed := BytesFromMemoryStream(OutputStream);
  finally
    OutputStream.Free;
    SourceStream.Free;
  end;
end;

function RunBenchmarkDecompress(const Source, Compressed: TBytes; const Options: TLzma2Options;
  const MinIterations: Integer; const MinTicks: Int64): TLzmaBenchmarkMeasurement;
var
  SourceStream: TBytesStream;
  OutputStream: TMemoryStream;
  Decoded: TBytes;
  Watch: TStopwatch;
begin
  Result := Default(TLzmaBenchmarkMeasurement);
  SourceStream := TBytesStream.Create(Compressed);
  OutputStream := TMemoryStream.Create;
  try
    Watch := TStopwatch.StartNew;
    repeat
      SourceStream.Position := 0;
      OutputStream.Clear;
      TLzma2.Decompress(SourceStream, OutputStream, Options);
      Inc(Result.Iterations);
    until (Result.Iterations >= MinIterations) and (Watch.ElapsedTicks >= MinTicks);
    Watch.Stop;
    Result.ElapsedTicks := Watch.ElapsedTicks;
    Decoded := BytesFromMemoryStream(OutputStream);
    if not BytesEqual(Source, Decoded) then
      RaiseLzmaError(SZ_ERROR_DATA, 'benchmark decompression mismatch');
  finally
    OutputStream.Free;
    SourceStream.Free;
  end;
end;

procedure RunBenchmarkCli;
var
  Benchmark: TLzmaBenchmarkOptions;
  Source: TBytes;
  CompressOptions: TLzma2Options;
  DecompressOptions: TLzma2Options;
  CompressMeasurement: TLzmaBenchmarkMeasurement;
  DecompressMeasurement: TLzmaBenchmarkMeasurement;
  Level: Integer;
  MinTicks: Int64;
  InputBytes: UInt64;
  Ratio: Double;
  DictionarySize: UInt64;
  ContainerName: string;
begin
  ParseBenchmarkCli(Benchmark);
  Source := TFile.ReadAllBytes(Benchmark.InputPath);
  InputBytes := UInt64(Length(Source));
  MinTicks := Round(Benchmark.Seconds * TStopwatch.Frequency);
  ContainerName := BenchmarkContainerName(Benchmark.Container);

  Writeln('Benchmark CSV:');
  Writeln('codec,inputName,inputBytes,level,threads,decompressThreads,dictionaryBytes,container,compressedBytes,ratio,compressionMBps,decompressionMBps,compressElapsedMs,decompressElapsedMs,compressIterations,decompressIterations');

  for Level := Benchmark.StartLevel to Benchmark.EndLevel do
  begin
    DictionarySize := Benchmark.DictionarySize;
    if DictionarySize = 0 then
      DictionarySize := DefaultDictionaryForLevel(TLzma2CompressionLevel(Level));

    CompressOptions := TLzma2.DefaultOptions;
    CompressOptions.Container := Benchmark.Container;
    CompressOptions.Level := TLzma2CompressionLevel(Level);
    CompressOptions.ThreadCount := Benchmark.Threads;
    CompressOptions.DictionarySize := DictionarySize;
    CompressOptions.Check := Benchmark.Check;
    CompressOptions.ArchiveFileName := ExtractFileName(Benchmark.InputPath);

    DecompressOptions := CompressOptions;
    DecompressOptions.ThreadCount := Benchmark.DecompressThreads;

    CompressMeasurement := RunBenchmarkCompress(Source, CompressOptions, Benchmark.Iterations, MinTicks);
    DecompressMeasurement := RunBenchmarkDecompress(Source, CompressMeasurement.Compressed, DecompressOptions,
      Benchmark.Iterations, MinTicks);

    if Length(CompressMeasurement.Compressed) = 0 then
      Ratio := 0
    else
      Ratio := InputBytes / Double(Length(CompressMeasurement.Compressed));

    Writeln(
      CsvField('LZMA2 Delphi'), ',',
      CsvField(ExtractFileName(Benchmark.InputPath)), ',',
      InputBytes, ',',
      Level, ',',
      Benchmark.Threads, ',',
      Benchmark.DecompressThreads, ',',
      DictionarySize, ',',
      CsvField(ContainerName), ',',
      Length(CompressMeasurement.Compressed), ',',
      CsvFloat(Ratio, 6), ',',
      CsvFloat(BenchmarkMBps(InputBytes, CompressMeasurement.ElapsedTicks, CompressMeasurement.Iterations), 3), ',',
      CsvFloat(BenchmarkMBps(InputBytes, DecompressMeasurement.ElapsedTicks, DecompressMeasurement.Iterations), 3), ',',
      CsvFloat(StopwatchTicksToMilliseconds(CompressMeasurement.ElapsedTicks), 3), ',',
      CsvFloat(StopwatchTicksToMilliseconds(DecompressMeasurement.ElapsedTicks), 3), ',',
      CompressMeasurement.Iterations, ',',
      DecompressMeasurement.Iterations);
  end;
end;

var
  Cli: TLzmaCli;
  Options: TLzma2Options;
  EncodeDiagnostics: TLzma2EncodeDiagnostics;
  DecodeDiagnostics: TLzma2DecodeDiagnostics;
  InputStream: TFileStream;
  OutputStream: TStream;
  Watch: TStopwatch;
  Progress: TLzma2ProgressEvent;
  TempOutputPath: string;
  FinalOutputReady: Boolean;
  SevenZipDirectoryExtract: Boolean;
  SevenZipArchiveEncode: Boolean;
  ArchiveInputBytes: UInt64;
  ArchiveEntries: TArray<TLzma7zEncodeEntry>;
  ArchiveSourcePaths: TArray<string>;
  ExtractedBytes: UInt64;
  StatsStream: TMemoryStream;
  StatsInputStream: TSizeOnlyStream;

begin
  try
    if IsHelpRequest then
    begin
      Usage;
      Halt(0);
    end;
    if IsVersionRequest then
    begin
      PrintVersion;
      Halt(0);
    end;
    if IsBenchmarkRequest then
    begin
      RunBenchmarkCli;
      Halt(0);
    end;

    if not ParseCli(Cli) then
    begin
      Usage;
      Halt(1);
    end;

    SevenZipDirectoryExtract := SevenZipNeedsDirectoryExtraction(Cli);
    SevenZipArchiveEncode := SevenZipNeedsArchiveEncode(Cli);
    if not SevenZipDirectoryExtract then
      ResolveArchiveDefaultOutput(Cli);
    if not SevenZipDirectoryExtract then
      ApplyOutputDirectory(Cli, Cli.ExplicitOutput);

    Options := Cli.Options;
    if Cli.Command = ccCompress then
      Options.ArchiveFileName := ExtractFileName(Cli.InputPath);
    TInterlocked.Exchange(GCancelRequested, 0);
    SetConsoleCtrlHandler(@ConsoleCtrlHandler, True);
    FinalOutputReady := False;
    TempOutputPath := '';
    try
      if SevenZipArchiveEncode then
      begin
        OutputStream := CreateOutputStream(Cli, TempOutputPath);
        StatsInputStream := nil;
        try
          Watch := TStopwatch.StartNew;
          EncodeDiagnostics := Default(TLzma2EncodeDiagnostics);
          Options.EncodeDiagnostics := @EncodeDiagnostics;
          CollectSevenZipEncodeEntries(Cli, ArchiveEntries, ArchiveSourcePaths, ArchiveInputBytes);
          StatsInputStream := TSizeOnlyStream.Create(ArchiveInputBytes);
          Progress := CreateProgressCallback(Cli, StatsInputStream, Watch);
          RunSevenZipArchiveEncode(Cli, ArchiveEntries, ArchiveSourcePaths, OutputStream, Options, Progress);
          Watch.Stop;
          PrintStats(Cli, StatsInputStream, OutputStream, Watch, EncodeDiagnostics, DecodeDiagnostics);
        finally
          StatsInputStream.Free;
          OutputStream.Free;
        end;
        FinalizeOutputFile(TempOutputPath, Cli.OutputPath);
        FinalOutputReady := True;
      end
      else
      begin
        InputStream := TFileStream.Create(Cli.InputPath, fmOpenRead or fmShareDenyWrite);
        try
          if SevenZipDirectoryExtract then
          begin
            Watch := TStopwatch.StartNew;
            Progress := CreateProgressCallback(Cli, InputStream, Watch);
            DecodeDiagnostics := Default(TLzma2DecodeDiagnostics);
            Options.DecodeDiagnostics := @DecodeDiagnostics;
            RunSevenZipDirectoryExtraction(Cli, InputStream, Options, Progress, ExtractedBytes);
            Watch.Stop;
            StatsStream := TMemoryStream.Create;
            try
              StatsStream.Size := ExtractedBytes;
              PrintStats(Cli, InputStream, StatsStream, Watch, EncodeDiagnostics, DecodeDiagnostics);
            finally
              StatsStream.Free;
            end;
            FinalOutputReady := True;
          end
          else
          begin
            OutputStream := CreateOutputStream(Cli, TempOutputPath);
            try
              Watch := TStopwatch.StartNew;
              Progress := CreateProgressCallback(Cli, InputStream, Watch);
              if Cli.Command = ccCompress then
              begin
                EncodeDiagnostics := Default(TLzma2EncodeDiagnostics);
                Options.EncodeDiagnostics := @EncodeDiagnostics;
                TLzma2.Compress(InputStream, OutputStream, Options, Progress)
              end
              else
              begin
                DecodeDiagnostics := Default(TLzma2DecodeDiagnostics);
                Options.DecodeDiagnostics := @DecodeDiagnostics;
                TLzma2.Decompress(InputStream, OutputStream, Options, Progress);
              end;
              Watch.Stop;
              PrintStats(Cli, InputStream, OutputStream, Watch, EncodeDiagnostics, DecodeDiagnostics);
            finally
              OutputStream.Free;
            end;
            FinalizeOutputFile(TempOutputPath, Cli.OutputPath);
            FinalOutputReady := True;
          end;
        finally
          InputStream.Free;
        end;
      end;
    finally
      SetConsoleCtrlHandler(@ConsoleCtrlHandler, False);
      if not FinalOutputReady then
        CleanupOutputFile(TempOutputPath);
    end;
  except
    on E: ELzmaCancelled do
    begin
      Writeln(ErrOutput, 'Cancelled: ', E.Message);
      Halt(CLI_CANCEL_EXIT_CODE);
    end;
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      Halt(2);
    end;
  end;
end.
