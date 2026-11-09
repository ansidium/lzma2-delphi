unit Lzma2GuiErrors;

interface

uses System.SysUtils;

type
  TGuiFailure = record
    Summary,Details:string;
  end;

function DescribeGuiFailure(const Error:Exception;const Language:Integer):TGuiFailure;

implementation

uses System.Classes, System.Threading, Lzma.Errors, Lzma.Types, Lzma2GuiCatalog;

function FailureKey(const Error:Exception):string;
var Code:SRes;
begin
  Result:='Task failed';
  if Error is ELzmaError then
  begin
    Code:=ELzmaError(Error).ResultCode;
    case Code of
      SZ_ERROR_DATA,SZ_ERROR_ARCHIVE,SZ_ERROR_NO_ARCHIVE,SZ_ERROR_INPUT_EOF:
        Exit('The archive is damaged or incomplete.');
      SZ_ERROR_CRC:Exit('The archive failed its integrity check.');
      SZ_ERROR_MEM:Exit('Not enough memory. Use a smaller dictionary or fewer threads.');
      SZ_ERROR_READ:Exit('The file could not be read. Check its path and access permissions.');
      SZ_ERROR_WRITE,SZ_ERROR_OUTPUT_EOF:
        Exit('The output could not be written. Check free space and access permissions.');
      SZ_ERROR_UNSUPPORTED:Exit('These settings are not supported by this archive format.');
      SZ_ERROR_PARAM:Exit('The operation parameters are invalid. Review the selected settings.');
      SZ_ERROR_THREAD:Exit('A worker could not be started. Try fewer threads.');
    end;
  end
  else if Error is EOutOfMemory then
    Result:='Not enough memory. Use a smaller dictionary or fewer threads.'
  else if (Error is EFOpenError) or (Error is EReadError) then
    Result:='The file could not be read. Check its path and access permissions.'
  else if (Error is EFCreateError) or (Error is EWriteError) then
    Result:='The output could not be written. Check free space and access permissions.';
end;

function DescribeGuiFailure(const Error:Exception;const Language:Integer):TGuiFailure;
var Summaries,Details:TStringList;
  procedure Collect(const Item:Exception);
  var I:Integer;Text:string;Aggregate:EAggregateException;
  begin
    if Item=nil then Exit;
    if Item is EAggregateException then
    begin
      Aggregate:=EAggregateException(Item);
      if Aggregate.Count>0 then
      begin
        for I:=0 to Aggregate.Count-1 do Collect(Aggregate.InnerExceptions[I]);
        Text:=Item.ClassName+': '+Item.Message;
        if Details.IndexOf(Text)<0 then Details.Add(Text);
        Exit;
      end;
    end;
    if not(Item is ELzmaCancelled) then
    begin
      Text:=GuiText(Language,FailureKey(Item));
      if Summaries.IndexOf(Text)<0 then Summaries.Add(Text);
    end;
    Text:=Item.ClassName+': '+Item.Message;
    if Item is ELzmaError then Text:=Text+' [SRes='+IntToStr(ELzmaError(Item).ResultCode)+']';
    if Details.IndexOf(Text)<0 then Details.Add(Text);
  end;
begin
  Summaries:=TStringList.Create;Details:=TStringList.Create;
  try
    Summaries.CaseSensitive:=True;Details.CaseSensitive:=True;
    Collect(Error);
    if Summaries.Count=0 then Summaries.Add(GuiText(Language,'Task failed'));
    Result.Summary:=TrimRight(Summaries.Text);Result.Details:=TrimRight(Details.Text);
  finally Details.Free;Summaries.Free;end;
end;

end.
