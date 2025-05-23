program FastLZMA2Test;

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes,
  FL2Common, FL2Pool, FL2Threading, FL2API;

procedure BasicTest;
var
  Input, OutputBuf, Decomp: TBytes;
  TestData: RawByteString;
  CompSize, DecompSize: NativeUInt;
begin
  TestData := 'FastLZMA2 Delphi test data.';
  Input := TEncoding.ASCII.GetBytes(string(TestData));

  SetLength(OutputBuf, FL2_compressBound(Length(Input)));
  CompSize := CompressBuffer(Input[0], Length(Input), OutputBuf[0], Length(OutputBuf), 1);

  if FL2_isError(CompSize) then
    raise Exception.Create(string(FL2_getErrorName(CompSize)));

  SetLength(Decomp, Length(Input));
  DecompSize := DecompressBuffer(OutputBuf[0], CompSize, Decomp[0], Length(Decomp));

  if FL2_isError(DecompSize) then
    raise Exception.Create(string(FL2_getErrorName(DecompSize)));

  if (DecompSize = Length(Input)) and CompareMem(@Input[0], @Decomp[0], DecompSize) then
    Writeln('Compression/decompression successful.')
  else
    Writeln('Data mismatch');
end;

begin
  try
    Writeln('FastLZMA2 version: ', string(FL2_versionString));
    BasicTest;
    Readln;
  except
    on E: Exception do
      Writeln(E.ClassName, ': ', E.Message);
  end;
end.
