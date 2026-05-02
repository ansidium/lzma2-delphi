unit Lzma.Errors;

interface

uses
  System.SysUtils,
  Lzma.Types;

type
  ELzmaError = class(Exception)
  private
    FResultCode: SRes;
  public
    constructor Create(const AResultCode: SRes; const Msg: string); reintroduce;
    property ResultCode: SRes read FResultCode;
  end;

  ELzmaInvalidParameter = class(ELzmaError);
  ELzmaUnsupportedProperties = class(ELzmaError);
  ELzmaDataError = class(ELzmaError);
  ELzmaInputEof = class(ELzmaError);
  ELzmaOutputEof = class(ELzmaError);
  ELzmaReadError = class(ELzmaError);
  ELzmaWriteError = class(ELzmaError);
  ELzmaChecksumError = class(ELzmaError);
  ELzmaMemoryError = class(ELzmaError);
  ELzmaCancelled = class(ELzmaError);
  ELzmaThreadError = class(ELzmaError);

procedure RaiseLzmaError(const ResultCode: SRes; const Msg: string);
procedure RaiseIfFalse(const Condition: Boolean; const ResultCode: SRes; const Msg: string);

implementation

constructor ELzmaError.Create(const AResultCode: SRes; const Msg: string);
begin
  inherited Create(Msg);
  FResultCode := AResultCode;
end;

procedure RaiseLzmaError(const ResultCode: SRes; const Msg: string);
begin
  case ResultCode of
    SZ_ERROR_PARAM:
      raise ELzmaInvalidParameter.Create(ResultCode, Msg);
    SZ_ERROR_UNSUPPORTED:
      raise ELzmaUnsupportedProperties.Create(ResultCode, Msg);
    SZ_ERROR_DATA, SZ_ERROR_ARCHIVE, SZ_ERROR_NO_ARCHIVE:
      raise ELzmaDataError.Create(ResultCode, Msg);
    SZ_ERROR_CRC:
      raise ELzmaChecksumError.Create(ResultCode, Msg);
    SZ_ERROR_INPUT_EOF:
      raise ELzmaInputEof.Create(ResultCode, Msg);
    SZ_ERROR_OUTPUT_EOF:
      raise ELzmaOutputEof.Create(ResultCode, Msg);
    SZ_ERROR_READ:
      raise ELzmaReadError.Create(ResultCode, Msg);
    SZ_ERROR_WRITE:
      raise ELzmaWriteError.Create(ResultCode, Msg);
    SZ_ERROR_MEM:
      raise ELzmaMemoryError.Create(ResultCode, Msg);
    SZ_ERROR_PROGRESS:
      raise ELzmaCancelled.Create(ResultCode, Msg);
    SZ_ERROR_THREAD:
      raise ELzmaThreadError.Create(ResultCode, Msg);
  else
    raise ELzmaError.Create(ResultCode, Msg);
  end;
end;

procedure RaiseIfFalse(const Condition: Boolean; const ResultCode: SRes; const Msg: string);
begin
  if not Condition then
    RaiseLzmaError(ResultCode, Msg);
end;

end.
