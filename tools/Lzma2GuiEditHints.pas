unit Lzma2GuiEditHints;

interface

uses System.Classes, System.Types, System.UITypes,Vcl.Controls, Vcl.StdCtrls, Vcl.Graphics,
  Winapi.Windows, Winapi.Messages;

type
  // A presentation component for an existing native EDIT. It owns no HWND,
  // keeps the VCL TextHint property and native cue messages, and leaves text
  // editing, selection, caret, IME and UI Automation with the original EDIT.
  TGuiEditHint = class(TComponent)
  private
    FEdit:TEdit;
    FPrevious:TWndMethod;
    FBuffer:Vcl.Graphics.TBitmap;
    FCue,FLastVclCue:string;
    FShowWhenFocused,FComposing:Boolean;
    FColor:TColor;
    function CueVisible:Boolean;
    procedure PaintCue(const DC:HDC);
    procedure WindowMessage(var Message:TMessage);
  protected
    procedure Notification(AComponent:TComponent;Operation:TOperation);override;
  public
    constructor CreateForEdit(const Edit:TEdit;const HintColor:TColor);
    destructor Destroy;override;
  end;

{$IFDEF GUI_LAYOUT_QA}
procedure AuditGuiEditHints(const Parent:TWinControl;const Background,TextColor,HintColor:TColor;
  var Checks:Integer;const Failures:TStrings);
{$ENDIF}

implementation

uses System.Math, System.SysUtils, Winapi.CommCtrl,Vcl.Forms;

constructor TGuiEditHint.CreateForEdit(const Edit:TEdit;const HintColor:TColor);
begin
  inherited Create(Edit);
  FEdit:=Edit;FColor:=HintColor;
  FBuffer:=Vcl.Graphics.TBitmap.Create;FBuffer.PixelFormat:=pf32bit;
  FCue:=Edit.TextHint;FLastVclCue:=FCue;
  FPrevious:=Edit.WindowProc;Edit.WindowProc:=WindowMessage;
  Edit.FreeNotification(Self);
  if Edit.HandleAllocated then
    SendMessage(Edit.Handle,EM_SETCUEBANNER,0,LPARAM(PChar(FCue)));
end;

destructor TGuiEditHint.Destroy;
var Current,Own:TWndMethod;
begin
  if FEdit<>nil then
  begin
    Current:=FEdit.WindowProc;Own:=WindowMessage;
    if (TMethod(Current).Code=TMethod(Own).Code) and
      (TMethod(Current).Data=TMethod(Own).Data) then
    begin
      FEdit.WindowProc:=FPrevious;
      if FEdit.HandleAllocated and not(csDestroying in FEdit.ComponentState) then
        SendMessage(FEdit.Handle,EM_SETCUEBANNER,Ord(FShowWhenFocused),LPARAM(PChar(FCue)));
    end;
    FEdit.RemoveFreeNotification(Self);
  end;
  FBuffer.Free;
  inherited;
end;

procedure TGuiEditHint.Notification(AComponent:TComponent;Operation:TOperation);
begin
  inherited;
  if (Operation=opRemove) and (AComponent=FEdit) then FEdit:=nil;
end;

function TGuiEditHint.CueVisible:Boolean;
begin
  if FEdit=nil then Exit(False);
  // TextHint can also change before the native window is allocated.
  if FEdit.TextHint<>FLastVclCue then
  begin FLastVclCue:=FEdit.TextHint;FCue:=FLastVclCue;end;
  Result:=(FCue<>'') and (FEdit.GetTextLen=0) and not FComposing and
    (FShowWhenFocused or not FEdit.Focused);
end;

procedure TGuiEditHint.PaintCue(const DC:HDC);
var R,TextBounds:TRect;Text:string;Flags:TTextFormat;
begin
  if (FEdit=nil) or (DC=0) then Exit;
  R:=FEdit.ClientRect;if R.IsEmpty then Exit;
  if (FBuffer.Width<>R.Width) or (FBuffer.Height<>R.Height) then
    FBuffer.SetSize(R.Width,R.Height);
  FBuffer.Canvas.Lock;
  try
    FBuffer.Canvas.Brush.Color:=FEdit.Color;FBuffer.Canvas.FillRect(R);
    FBuffer.Canvas.Font.Assign(FEdit.Font);FBuffer.Canvas.Font.Color:=FColor;
    TextBounds:=R;
    SendMessage(FEdit.Handle,EM_GETRECT,0,LPARAM(@TextBounds));
    IntersectRect(TextBounds,TextBounds,R);
    Flags:=[tfSingleLine,tfVerticalCenter,tfNoPrefix,tfEndEllipsis];
    case FEdit.Alignment of
      taRightJustify:Include(Flags,tfRight);
      taCenter:Include(Flags,tfCenter);
    else Include(Flags,tfLeft);end;
    if FEdit.UseRightToLeftReading then Include(Flags,tfRtlReading);
    Text:=FCue;FBuffer.Canvas.TextRect(TextBounds,Text,Flags);
    BitBlt(DC,0,0,R.Width,R.Height,FBuffer.Canvas.Handle,0,0,SRCCOPY);
  finally FBuffer.Canvas.Unlock;end;
end;

procedure TGuiEditHint.WindowMessage(var Message:TMessage);
var Native:TMessage;Empty:WideChar;DC:HDC;PS:TPaintStruct;Count:NativeInt;
begin
  if FEdit=nil then begin FPrevious(Message);Exit;end;
  if Message.Msg=EM_SETCUEBANNER then
  begin
    if Message.LParam=0 then FCue:='' else FCue:=PChar(Message.LParam);
    FLastVclCue:=FEdit.TextHint;FShowWhenFocused:=Message.WParam<>0;
    // Disable only the native cue pixels. Expose the original cue through
    // EM_GETCUEBANNER below; two painters must not compete for the same text.
    Native:=Message;Empty:=#0;Native.LParam:=LPARAM(@Empty);
    FPrevious(Native);Message.Result:=Native.Result;FEdit.Invalidate;Exit;
  end;
  if Message.Msg=EM_GETCUEBANNER then
  begin
    // Native EDIT reports success for a valid destination with capacity zero
    // and leaves that destination untouched.
    Message.Result:=Ord(Message.WParam<>0);
    if (Message.WParam<>0) and (Message.LParam>0) then
    begin
      Count:=Min(NativeInt(Length(FCue)),NativeInt(Message.LParam)-1);
      if Count>0 then Move(PChar(FCue)^,PChar(Message.WParam)^,Count*SizeOf(Char));
      PChar(Message.WParam)[Count]:=#0;Message.Result:=1;
    end;
    Exit;
  end;
  if Message.Msg=WM_IME_STARTCOMPOSITION then FComposing:=True;
  if Message.Msg=WM_IME_ENDCOMPOSITION then FComposing:=False;
  if ((Message.Msg=WM_PAINT) or (Message.Msg=WM_ERASEBKGND) or
    (Message.Msg=WM_PRINTCLIENT)) and CueVisible then
  begin
    if Message.Msg=WM_ERASEBKGND then
    begin PaintCue(HDC(Message.WParam));Message.Result:=1;Exit;end;
    if Message.Msg=WM_PRINTCLIENT then
    begin PaintCue(HDC(Message.WParam));Message.Result:=1;Exit;end;
    if Message.Msg=WM_PAINT then
    begin
      DC:=HDC(Message.WParam);
      if DC=0 then DC:=BeginPaint(FEdit.Handle,PS);
      try PaintCue(DC);
      finally if Message.WParam=0 then EndPaint(FEdit.Handle,PS);end;
      Message.Result:=0;Exit;
    end;
  end;
  FPrevious(Message);
  case Message.Msg of
    WM_SETTEXT,WM_SETFOCUS,WM_KILLFOCUS,WM_SETFONT,WM_IME_ENDCOMPOSITION,
    CM_COLORCHANGED,CM_FONTCHANGED,CM_ENABLEDCHANGED:FEdit.Invalidate;
  end;
end;

{$IFDEF GUI_LAYOUT_QA}
procedure AuditGuiEditHints(const Parent:TWinControl;const Background,TextColor,HintColor:TColor;
  var Checks:Integer;const Failures:TStrings);
const Captures:array[0..3] of Integer=(0,1,2,64);
      Cues:array[0..2] of string=('','gjpqy','路径 日本語 한국어');
var Native,Themed:TEdit;Hint:TGuiEditHint;Capacity,I:Integer;Cue:string;
    A,B:array[0..127] of Char;RA,RB:LRESULT;Bitmap:Vcl.Graphics.TBitmap;
    Pixels:Integer;Color:TColor;Opaque:Boolean;
  procedure Check(const Value:Boolean;const Detail:string);
  begin Inc(Checks);if not Value then Failures.Add('Native cue contract: '+Detail);end;
  procedure Configure(const Edit:TEdit);
  begin
    Edit.Visible:=False;Edit.Parent:=Parent;Edit.BorderStyle:=bsNone;Edit.Ctl3D:=False;
    Edit.Color:=Background;Edit.Font.Name:='Segoe UI';Edit.Font.Size:=11;
    Edit.Font.Color:=TextColor;Edit.StyleElements:=[];Edit.Width:=300;
  end;
begin
  Native:=TEdit.Create(Parent);Themed:=TEdit.Create(Parent);Hint:=nil;Bitmap:=nil;
  try
    Configure(Native);Configure(Themed);Hint:=TGuiEditHint.CreateForEdit(Themed,HintColor);
    Check(GetClassName(Native.Handle,A,Length(A))>0,'Native class is available');
    Check(GetClassName(Themed.Handle,B,Length(B))>0,'Themed class is available');
    Check(StrComp(A,B)=0,'Native HWND class stays unchanged');
    for Cue in Cues do
    begin
      Native.TextHint:=Cue;Themed.TextHint:=Cue;
      for Capacity in Captures do
      begin
        for I:=0 to High(A) do begin A[I]:=#$1234;B[I]:=#$1234;end;
        RA:=Native.Perform(EM_GETCUEBANNER,WPARAM(@A[0]),Capacity);
        RB:=Themed.Perform(EM_GETCUEBANNER,WPARAM(@B[0]),Capacity);
        Check(RA=RB,'Cue getter result matches native EDIT, capacity '+IntToStr(Capacity));
        Check(CompareMem(@A[0],@B[0],SizeOf(A)),'Cue getter buffer matches native EDIT, capacity '+IntToStr(Capacity));
      end;
    end;
    Cue:='direct native cue';
    RA:=Native.Perform(EM_SETCUEBANNER,1,LPARAM(PChar(Cue)));
    RB:=Themed.Perform(EM_SETCUEBANNER,1,LPARAM(PChar(Cue)));
    Check(RA=RB,'Direct native cue setter result');
    Native.Perform(EM_GETCUEBANNER,WPARAM(@A[0]),Length(A));
    Themed.Perform(EM_GETCUEBANNER,WPARAM(@B[0]),Length(B));
    Check(StrComp(A,B)=0,'Direct native cue remains readable');
    Bitmap:=Vcl.Graphics.TBitmap.Create;Bitmap.PixelFormat:=pf32bit;
    Bitmap.SetSize(Themed.ClientWidth,Themed.ClientHeight);
    Bitmap.Canvas.Lock;
    try
      Bitmap.Canvas.Brush.Color:=clFuchsia;Bitmap.Canvas.FillRect(Rect(0,0,Bitmap.Width,Bitmap.Height));
      Themed.Perform(WM_PRINTCLIENT,WPARAM(Bitmap.Canvas.Handle),PRF_CLIENT or PRF_ERASEBKGND);
      Pixels:=0;Opaque:=True;
      for I:=0 to Bitmap.Width*Bitmap.Height-1 do
      begin
        Color:=Bitmap.Canvas.Pixels[I mod Bitmap.Width,I div Bitmap.Width];
        if Color=ColorToRGB(HintColor) then Inc(Pixels);
        if Color=clFuchsia then Opaque:=False;
      end;
      Check(Opaque,'Opaque hint snapshot');
      Check(Pixels>0,'Themed hint uses the supplied palette');
    finally Bitmap.Canvas.Unlock;end;
    Themed.Text:='native editing value';
    Check(Themed.Text='native editing value','Text editing value is unchanged');
    Hint.Free;Hint:=nil;
    Themed.Perform(EM_GETCUEBANNER,WPARAM(@B[0]),Length(B));
    Check(StrComp(A,B)=0,'Removing the presenter restores the native cue');
  finally Bitmap.Free;Hint.Free;Themed.Free;Native.Free;end;
end;
{$ENDIF}

end.
