unit Lzma2GuiHints;

interface

uses System.Classes,System.Types,Vcl.Controls,Vcl.Graphics,Winapi.Windows,Winapi.Messages;

procedure ConfigureGuiHints(const Surface,Border,Text:TColor);

{$IFDEF GUI_LAYOUT_QA}
procedure AuditGuiHints(var Checks:Integer;const Failures:TStrings);
{$ENDIF}

implementation

uses System.Math,System.SysUtils,Vcl.Forms;

type
  TGuiHintWindow=class(THintWindow)
  private
    FBuffer:Vcl.Graphics.TBitmap;
    FPpi:Integer;
    FPresenting:Boolean;
    procedure CMTextChanged(var Message:TMessage);message CM_TEXTCHANGED;
    procedure UpdateRegion;
  protected
    procedure CreateParams(var Params:TCreateParams);override;
    procedure Paint;override;
    procedure NCPaint(DC:HDC);override;
    procedure Resize;override;
  public
    constructor Create(AOwner:TComponent);override;
    destructor Destroy;override;
    function CalcHintRect(MaxWidth:Integer;const AHint:string;AData:TCustomData):TRect;override;
    procedure ActivateHint(Rect:TRect;const AHint:string);override;
  end;

var HintSurface,HintBorder,HintText:TColor;

procedure ConfigureGuiHints(const Surface,Border,Text:TColor);
begin
  HintSurface:=Surface;HintBorder:=Border;HintText:=Text;
  Application.HintColor:=Surface;
  HintWindowClass:=TGuiHintWindow;
end;

constructor TGuiHintWindow.Create(AOwner:TComponent);
begin
  inherited;
  FPpi:=Screen.PixelsPerInch;
  Color:=HintSurface;StyleElements:=[];DoubleBuffered:=True;
  ControlStyle:=ControlStyle+[csOpaque];
  FBuffer:=Vcl.Graphics.TBitmap.Create;FBuffer.PixelFormat:=pf32bit;
end;

destructor TGuiHintWindow.Destroy;
begin
  FreeAndNil(FBuffer);
  inherited;
end;

procedure TGuiHintWindow.CreateParams(var Params:TCreateParams);
begin
  inherited;
  Params.Style:=Params.Style and not WS_BORDER;
  Params.WindowClass.Style:=Params.WindowClass.Style and not CS_DROPSHADOW;
end;

function TGuiHintWindow.CalcHintRect(MaxWidth:Integer;const AHint:string;AData:TCustomData):TRect;
var PadX,PadY:Integer;
begin
  FPpi:=Screen.PixelsPerInch;
  if Screen.ActiveCustomForm<>nil then FPpi:=Screen.ActiveCustomForm.CurrentPPI;
  PadX:=MulDiv(8,FPpi,96);PadY:=MulDiv(6,FPpi,96);
  // The RTL owns font selection, DPI and Unicode/BiDi measurement. Replace
  // its 6x2 client padding; our presenter adds no extra activation padding.
  Result:=inherited CalcHintRect(Max(1,MaxWidth-2*PadX),AHint,AData);
  Inc(Result.Right,2*PadX-6);Inc(Result.Bottom,2*PadY-2);
end;

procedure TGuiHintWindow.CMTextChanged(var Message:TMessage);
begin
  if FPresenting then begin Message.Result:=0;Exit;end;
  inherited;
end;

procedure TGuiHintWindow.UpdateRegion;
var Region:HRGN;Diameter:Integer;
begin
  if not HandleAllocated or (Width<=0) or (Height<=0) then Exit;
  Diameter:=Max(2,MulDiv(12,Max(96,FPpi),96));
  Region:=CreateRoundRectRgn(0,0,Width+1,Height+1,Diameter,Diameter);
  if Region<>0 then
    if SetWindowRgn(Handle,Region,False)=0 then DeleteObject(Region);
end;

procedure TGuiHintWindow.Resize;
begin
  inherited;
  UpdateRegion;
end;

procedure TGuiHintWindow.ActivateHint(Rect:TRect;const AHint:string);
var Area:TRect;W,H,X,Y:Integer;
begin
  FPresenting:=True;
  try
    Caption:=AHint;
    Area:=Screen.MonitorFromPoint(Rect.TopLeft).WorkareaRect;
    W:=Min(Rect.Width,Area.Width);H:=Min(Rect.Height,Area.Height);
    X:=EnsureRange(Rect.Left,Area.Left,Area.Right-W);
    Y:=EnsureRange(Rect.Top,Area.Top,Area.Bottom-H);
    ParentWindow:=Application.Handle;
    SetBounds(X,Y,W,H);UpdateRegion;
    SetWindowPos(Handle,HWND_TOPMOST,X,Y,W,H,SWP_NOACTIVATE or SWP_NOOWNERZORDER);
    // A frequently repeated utility hint appears immediately. No process-
    // global animation hooks or Windows effect settings are changed.
    ShowWindow(Handle,SW_SHOWNOACTIVATE);Invalidate;Update;
  finally FPresenting:=False;end;
end;

procedure TGuiHintWindow.NCPaint(DC:HDC);
begin
  // Paint owns the single boundary; the RTL raised native edge is absent.
end;

procedure TGuiHintWindow.Paint;
var R,TextBounds:TRect;Diameter:Integer;
begin
  if FBuffer=nil then Exit;
  R:=ClientRect;if R.IsEmpty then Exit;
  if (FBuffer.Width<>R.Width) or (FBuffer.Height<>R.Height) then
    FBuffer.SetSize(R.Width,R.Height);
  FBuffer.Canvas.Lock;
  try
    FBuffer.Canvas.Brush.Color:=HintSurface;FBuffer.Canvas.FillRect(R);
    FBuffer.Canvas.Pen.Color:=HintBorder;FBuffer.Canvas.Pen.Width:=1;
    Diameter:=Max(2,MulDiv(12,Max(96,FPpi),96));
    FBuffer.Canvas.RoundRect(0,0,R.Width,R.Height,Diameter,Diameter);
    FBuffer.Canvas.Font.Assign(Canvas.Font);FBuffer.Canvas.Font.Color:=HintText;
    FBuffer.Canvas.Brush.Style:=bsClear;
    TextBounds:=R;InflateRect(TextBounds,-MulDiv(8,FPpi,96),-MulDiv(6,FPpi,96));
    Winapi.Windows.DrawText(FBuffer.Canvas.Handle,PChar(Caption),Length(Caption),TextBounds,
      DT_LEFT or DT_NOPREFIX or DT_WORDBREAK or DrawTextBiDiModeFlagsReadingOnly);
    FBuffer.Canvas.Brush.Style:=bsSolid;
    BitBlt(Canvas.Handle,0,0,R.Width,R.Height,FBuffer.Canvas.Handle,0,0,SRCCOPY);
  finally FBuffer.Canvas.Unlock;end;
end;

{$IFDEF GUI_LAYOUT_QA}
procedure AuditGuiHints(var Checks:Integer;const Failures:TStrings);
var Hint:TGuiHintWindow;Bitmap:Vcl.Graphics.TBitmap;R:TRect;Text:string;
    I,SurfacePixels,WhitePixels:Integer;C:TColor;
  procedure Check(const Value:Boolean;const Detail:string);
  begin Inc(Checks);if not Value then Failures.Add('Themed hint: '+Detail);end;
begin
  Hint:=TGuiHintWindow.Create(nil);Bitmap:=nil;
  try
    Text:='Agjp_'+#$8DEF#$5F84+' '+#$D55C#$AD6D#$C5B4;
    R:=Hint.CalcHintRect(800,Text,nil);Hint.Caption:=Text;
    Hint.SetBounds(0,0,R.Width,R.Height);
    Check((R.Width>32) and (R.Height>12),'Unicode text has padded bounds');
    Check(Hint.Perform(WM_NCHITTEST,0,0)=HTTRANSPARENT,'Hint does not intercept mouse input');
    Check((GetWindowLong(Hint.Handle,GWL_STYLE) and WS_BORDER)=0,'No competing native frame');
    Check(Hint.Caption=Text,'Full Unicode caption remains available');
    Bitmap:=Vcl.Graphics.TBitmap.Create;Bitmap.PixelFormat:=pf32bit;
    Bitmap.SetSize(R.Width,R.Height);
    Hint.PaintTo(Bitmap.Canvas.Handle,0,0);
    SurfacePixels:=0;WhitePixels:=0;
    for I:=0 to Bitmap.Width*Bitmap.Height-1 do
    begin
      C:=Bitmap.Canvas.Pixels[I mod Bitmap.Width,I div Bitmap.Width];
      if C=ColorToRGB(HintSurface) then Inc(SurfacePixels);
      if C=clWhite then Inc(WhitePixels);
    end;
    Check(SurfacePixels>Bitmap.Width*Bitmap.Height div 2,'Opaque supplied palette owns the surface');
    Check(WhitePixels=0,'Native white tooltip pixels are absent');
  finally Bitmap.Free;Hint.Free;end;
end;
{$ENDIF}

end.
