unit Lzma2ThreadChoice;

interface

type
  // Requested value is independent from the visible list position and codec
  // admission. Zero means Auto; a positive value preserves the user's choice.
  TThreadChoiceState = record
  private
    FProcessorCount,FRequestedWorkers: Integer;
    function GetCustomIndex: Integer;
    function GetChoiceCount: Integer;
    function GetChoiceIndex: Integer;
    procedure SetRequestedWorkers(const Value: Integer);
  public
    class function Create(const ProcessorCount: Integer;
      const RequestedWorkers: Integer=0): TThreadChoiceState; static;
    function IsNumericChoice(const Index: Integer): Boolean;
    procedure SelectNumericChoice(const Index: Integer);
    property ProcessorCount: Integer read FProcessorCount;
    property RequestedWorkers: Integer read FRequestedWorkers write SetRequestedWorkers;
    property CustomIndex: Integer read GetCustomIndex;
    property ChoiceCount: Integer read GetChoiceCount;
    property ChoiceIndex: Integer read GetChoiceIndex;
  end;

implementation

uses System.SysUtils;

class function TThreadChoiceState.Create(const ProcessorCount,RequestedWorkers: Integer): TThreadChoiceState;
begin
  if (ProcessorCount<1) or (ProcessorCount>High(Integer)-2) then
    raise EArgumentOutOfRangeException.Create('Invalid available processor count');
  Result.FProcessorCount:=ProcessorCount;
  Result.SetRequestedWorkers(RequestedWorkers);
end;

function TThreadChoiceState.GetCustomIndex: Integer;
begin Result:=FProcessorCount+1;end;

function TThreadChoiceState.GetChoiceCount: Integer;
begin Result:=FProcessorCount+2;end;

function TThreadChoiceState.GetChoiceIndex: Integer;
begin
  if FRequestedWorkers<=FProcessorCount then Result:=FRequestedWorkers
  else Result:=CustomIndex;
end;

procedure TThreadChoiceState.SetRequestedWorkers(const Value: Integer);
begin
  if Value<0 then raise EArgumentOutOfRangeException.Create('Thread count must be Auto or positive');
  FRequestedWorkers:=Value;
end;

function TThreadChoiceState.IsNumericChoice(const Index: Integer): Boolean;
begin Result:=(Index>=0) and (Index<=FProcessorCount);end;

procedure TThreadChoiceState.SelectNumericChoice(const Index: Integer);
begin
  if not IsNumericChoice(Index) then
    raise EArgumentOutOfRangeException.Create('Custom thread choice requires an explicit value');
  SetRequestedWorkers(Index);
end;

end.
