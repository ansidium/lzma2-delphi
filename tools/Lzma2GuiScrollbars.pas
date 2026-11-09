unit Lzma2GuiScrollbars;

interface

uses System.Classes, System.Types, Vcl.Controls, Vcl.Graphics, Winapi.Windows,
  Winapi.Messages;

const
  GuiPopupRowHeight=28;
  GuiPopupVisibleRows=7;
  GuiPopupScrollbarWidth=14;
  GuiPopupCornerRadius=6;

type
  TGuiListColors = record
    Background, Text, Muted, Selection, Hover, Accent: TColor;
  end;

  TGuiListDrawRow = procedure(const Canvas:TCanvas;const Index:Integer;
    const Bounds:TRect;const Selected:Boolean) of object;

  TGuiListScrollBar = class(TCustomControl)
  private
    FPosition, FMaximum, FPageSize, FDragOffset: Integer;
    FDragging, FHover, FExternalPaint: Boolean;
    FCaptureTarget: HWND;
    FColors: TGuiListColors;
    procedure SetPosition(const Value: Integer);
    procedure SetColors(const Value: TGuiListColors);
    procedure Thumb(out Top, Height: Integer);
    procedure CMMouseLeave(var Message: TMessage); message CM_MOUSELEAVE;
    procedure WMCaptureChanged(var Message: TMessage); message WM_CAPTURECHANGED;
  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X,Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X,Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X,Y: Integer); override;
  public
    Changed: TNotifyEvent;
    constructor Create(AOwner: TComponent); override;
    procedure Configure(const Count, PageSize, Position: Integer);
    procedure Render(const Target:TCanvas;const Bounds:TRect);
    procedure PointerMove(const X,Y: Integer; const Inside: Boolean);
    procedure PointerDown(const X,Y: Integer);
    procedure PointerUp(const X,Y: Integer);
    procedure CancelPointer;
    property Position: Integer read FPosition write SetPosition;
    property Maximum: Integer read FMaximum;
    property ThumbDragging: Boolean read FDragging;
    property Hovering: Boolean read FHover;
    property ExternalPaint: Boolean read FExternalPaint write FExternalPaint;
    property CaptureTarget: HWND read FCaptureTarget write FCaptureTarget;
    property Colors: TGuiListColors read FColors write SetColors;
  end;

  // Native list state, keyboard, capture and UIA remain with Windows. A
  // single owner renders the rows and scrollbar; native automatic drawing is
  // disabled so it cannot expose a second scrollbar between our paints.
  TNativeListPresenter = class(TComponent)
  private
    FList: HWND;
    FBar: TGuiListScrollBar;
    FRows:Vcl.Graphics.TBitmap;
    FDrawRow:TGuiListDrawRow;
    FDrawingRows,FRedrawEnabled:Boolean;
    FOpening:Boolean;
    FUpdating, FScrollPointer, FInsideScroll, FPainting: Boolean;
    FPpi, FWheelDelta: Integer;
    FRegionWidth,FRegionHeight,FRegionPpi: Integer;
    procedure Scrolled(Sender: TObject);
    procedure PaintNative(const DC:HDC=0);
    procedure PaintRows(const DC:HDC=0);
    function MessageProc(const Msg: UINT; const WParam: WPARAM; const LParam: LPARAM): LRESULT;
  public
    constructor CreateForList(AOwner: TComponent; const List: HWND;
      const Ppi: Integer; const Colors: TGuiListColors;
      const DrawRow:TGuiListDrawRow);
    destructor Destroy; override;
    procedure PrepareOpen;
    procedure Refresh(const Ppi: Integer);
  end;

function WheelScrollLines(const Delta, PageSize, Count: Integer;
  var Remainder: Integer): Integer;

implementation

uses System.Math, System.SysUtils, Winapi.CommCtrl;

function WheelScrollLines(const Delta, PageSize, Count: Integer;
  var Remainder: Integer): Integer;
var Lines: UINT; Steps: Integer;
begin
  Inc(Remainder,Delta);
  Steps:=Remainder div WHEEL_DELTA;
  Dec(Remainder,Steps*WHEEL_DELTA);
  Lines:=3;
  SystemParametersInfo(SPI_GETWHEELSCROLLLINES,0,@Lines,0);
  if Lines=WHEEL_PAGESCROLL then Lines:=Max(1,PageSize);
  Result:=Integer(EnsureRange(Int64(Steps)*Min(Lines,UINT(Max(0,Count))),
    Int64(Low(Integer)),Int64(High(Integer))));
end;

constructor TGuiListScrollBar.Create(AOwner: TComponent);
begin
  inherited;
  ControlStyle:=ControlStyle+[csOpaque];
  DoubleBuffered:=True;
  TabStop:=False;
  Visible:=False;
end;

procedure TGuiListScrollBar.Configure(const Count,PageSize,Position: Integer);
begin
  FPageSize:=Max(1,PageSize);
  FMaximum:=Max(0,Count-FPageSize);
  FPosition:=EnsureRange(Position,0,FMaximum);
  if FMaximum=0 then CancelPointer;
  Visible:=(FMaximum>0) and not FExternalPaint;
  Invalidate;
end;

procedure TGuiListScrollBar.SetColors(const Value: TGuiListColors);
begin FColors:=Value;Color:=Value.Background;Invalidate;end;

procedure TGuiListScrollBar.Thumb(out Top,Height: Integer);
var Track: Integer;
begin
  Track:=Max(1,Self.Height-ScaleValue(8));
  Height:=Track;
  if FMaximum>0 then Height:=Min(Track,Max(ScaleValue(24),
    MulDiv(Track,FPageSize,FMaximum+FPageSize)));
  Top:=ScaleValue(4);
  if FMaximum>0 then Inc(Top,MulDiv(Track-Height,FPosition,FMaximum));
end;

procedure TGuiListScrollBar.SetPosition(const Value: Integer);
var P: Integer;
begin
  P:=EnsureRange(Value,0,FMaximum);
  if P=FPosition then Exit;
  FPosition:=P;Invalidate;
  if Assigned(Changed) then Changed(Self);
end;

procedure TGuiListScrollBar.Paint;
begin Render(Canvas,ClientRect);end;

procedure TGuiListScrollBar.Render(const Target:TCanvas;const Bounds:TRect);
var T,H,W: Integer;
begin
  Target.Brush.Color:=FColors.Background;Target.FillRect(Bounds);
  if FMaximum=0 then Exit;
  Thumb(T,H);W:=ScaleValue(4);Target.Brush.Color:=FColors.Muted;
  if FHover or FDragging then begin W:=ScaleValue(6);Target.Brush.Color:=FColors.Accent;end;
  Target.Pen.Style:=psClear;
  Target.RoundRect(Bounds.Left+(Bounds.Width-W) div 2,Bounds.Top+T,
    Bounds.Left+(Bounds.Width+W) div 2,Bounds.Top+T+H,W,W);
  Target.Pen.Style:=psSolid;
end;

procedure TGuiListScrollBar.MouseDown(Button: TMouseButton; Shift: TShiftState; X,Y: Integer);
var T,H: Integer;
begin
  inherited;
  if (Button<>mbLeft) or (FMaximum=0) then Exit;
  Thumb(T,H);
  if (Y>=T) and (Y<T+H) then
  begin
    FDragOffset:=Y-T;FDragging:=True;
    if FCaptureTarget<>0 then
    begin
      // A dropped native combo already owns capture. Reacquiring it sends
      // capture-change notifications that make its list cancel the popup.
      if GetCapture<>FCaptureTarget then SetCapture(FCaptureTarget);
    end
    else MouseCapture:=True;
  end
  else if Y<T then Position:=Position-FPageSize else Position:=Position+FPageSize;
  Invalidate;
end;

procedure TGuiListScrollBar.MouseMove(Shift: TShiftState; X,Y: Integer);
var T,H,Travel: Integer;
begin
  inherited;FHover:=True;
  if FDragging then
  begin
    Thumb(T,H);Travel:=Height-ScaleValue(8)-H;
    if Travel>0 then Position:=MulDiv(Y-FDragOffset-ScaleValue(4),FMaximum,Travel);
  end;
  Invalidate;
end;

procedure TGuiListScrollBar.MouseUp(Button: TMouseButton; Shift: TShiftState; X,Y: Integer);
begin
  inherited;
  if Button<>mbLeft then Exit;
  FDragging:=False;
  if FCaptureTarget=0 then MouseCapture:=False;
  Invalidate;
end;

procedure TGuiListScrollBar.CMMouseLeave(var Message: TMessage);
begin inherited;FHover:=False;Invalidate;end;

procedure TGuiListScrollBar.CancelPointer;
var WasDragging:Boolean;Target:HWND;
begin
  WasDragging:=FDragging;FDragging:=False;FHover:=False;
  if WasDragging then
  begin
    Target:=FCaptureTarget;
    if (Target=0) and HandleAllocated then Target:=Handle;
    if (Target<>0) and (GetCapture=Target) then ReleaseCapture;
  end;
  Invalidate;
end;

procedure TGuiListScrollBar.WMCaptureChanged(var Message:TMessage);
begin inherited;CancelPointer;end;

procedure TGuiListScrollBar.PointerMove(const X,Y: Integer; const Inside: Boolean);
begin
  if Inside or FDragging then MouseMove([],X,Y)
  else if FHover then begin FHover:=False;Invalidate;end;
end;
procedure TGuiListScrollBar.PointerDown(const X,Y: Integer);
begin MouseDown(mbLeft,[],X,Y);end;
procedure TGuiListScrollBar.PointerUp(const X,Y: Integer);
begin MouseUp(mbLeft,[],X,Y);end;

function NativeListSubclass(Wnd: HWND; Msg: UINT; WParam: WPARAM; LParam: LPARAM;
  Id: UINT_PTR; Data: DWORD_PTR): LRESULT; stdcall;
begin
  Result:=TNativeListPresenter(Pointer(Data)).MessageProc(Msg,WParam,LParam);
end;

constructor TNativeListPresenter.CreateForList(AOwner: TComponent; const List: HWND;
  const Ppi: Integer; const Colors: TGuiListColors;const DrawRow:TGuiListDrawRow);
var Controls: TInitCommonControlsEx;
begin
  inherited Create(AOwner);
  InitCommonControls;
  Controls.dwSize:=SizeOf(Controls);Controls.dwICC:=ICC_STANDARD_CLASSES;
  if not InitCommonControlsEx(Controls) then RaiseLastOSError;
  FList:=List;FPpi:=Ppi;
  FDrawRow:=DrawRow;FRedrawEnabled:=True;
  FRows:=Vcl.Graphics.TBitmap.Create;FRows.PixelFormat:=pf32bit;
  FBar:=TGuiListScrollBar.Create(Self);
  FBar.Colors:=Colors;FBar.ExternalPaint:=True;
  FBar.CaptureTarget:=List;FBar.Changed:=Scrolled;
  // LISTBOX handles WM_SETREDRAW itself (LBS_NOREDRAW) and retains visibility
  // and native input state. Suppress automatic drawing before installing the
  // presenter; subsequent application batching is tracked by MessageProc.
  SendMessage(List,WM_SETREDRAW,0,0);
  if not SetWindowSubclass(List,NativeListSubclass,NativeUInt(Self),NativeUInt(Self)) then RaiseLastOSError;
  SetWindowLongPtr(List,GWL_STYLE,GetWindowLongPtr(List,GWL_STYLE) or WS_CLIPCHILDREN);
  Refresh(Ppi);
end;

destructor TNativeListPresenter.Destroy;
begin
  if FBar<>nil then FBar.CancelPointer;
  if FList<>0 then RemoveWindowSubclass(FList,NativeListSubclass,NativeUInt(Self));
  FreeAndNil(FRows);FreeAndNil(FBar);inherited;
end;

procedure TNativeListPresenter.PaintRows(const DC:HDC);
var R,Row:TRect;Top,Count,Selected,Height,I,Last:Integer;
    TargetDC:HDC;
begin
  if FDrawingRows or not FRedrawEnabled or (FList=0) or (FRows=nil) or
    not Assigned(FDrawRow) or ((DC=0) and not IsWindowVisible(FList)) then Exit;
  GetClientRect(FList,R);if R.IsEmpty then Exit;
  FDrawingRows:=True;
  try
    if (FRows.Width<>R.Width) or (FRows.Height<>R.Height) then FRows.SetSize(R.Width,R.Height);
    FRows.Canvas.Lock;
    try
    FRows.Canvas.Brush.Color:=FBar.Colors.Background;FRows.Canvas.FillRect(R);
    Count:=Max(0,Integer(SendMessage(FList,LB_GETCOUNT,0,0)));
    Top:=Max(0,Integer(SendMessage(FList,LB_GETTOPINDEX,0,0)));
    Height:=Max(1,Integer(SendMessage(FList,LB_GETITEMHEIGHT,0,0)));
    Selected:=Integer(SendMessage(FList,LB_GETCURSEL,0,0));
    Last:=Min(Count-1,Top+(R.Height+Height-1) div Height-1);
    for I:=Top to Last do
      if SendMessage(FList,LB_GETITEMRECT,I,LPARAM(@Row))<>LB_ERR then
        FDrawRow(FRows.Canvas,I,Row,I=Selected);
    TargetDC:=DC;if TargetDC=0 then TargetDC:=GetDC(FList);
    if TargetDC<>0 then
    try BitBlt(TargetDC,0,0,R.Width,R.Height,FRows.Canvas.Handle,0,0,SRCCOPY);
    finally if DC=0 then ReleaseDC(FList,TargetDC);end;
    finally FRows.Canvas.Unlock;end;
  finally FDrawingRows:=False;end;
end;

procedure TNativeListPresenter.Scrolled(Sender: TObject);
begin
  if (FList<>0) and not FUpdating then SendMessage(FList,LB_SETTOPINDEX,FBar.Position,0);
end;

procedure TNativeListPresenter.PrepareOpen;
begin
  FOpening:=True;
end;

procedure TNativeListPresenter.PaintNative(const DC:HDC);
var Info:TScrollBarInfo;WindowRect,Bounds,ClientBounds:TRect;Origin:TPoint;
    TargetDC:HDC;Target:TCanvas;Saved:Integer;
begin
  if FPainting or not FRedrawEnabled or (FList=0) or (FBar=nil) or
    ((DC=0) and not IsWindowVisible(FList)) or
    not GetWindowRect(FList,WindowRect) then Exit;
  FPainting:=True;
  try
    Origin:=Point(0,0);ClientToScreen(FList,Origin);
    GetClientRect(FList,ClientBounds);
    OffsetRect(ClientBounds,Origin.X-WindowRect.Left,Origin.Y-WindowRect.Top);
    TargetDC:=DC;
    if TargetDC=0 then TargetDC:=GetWindowDC(FList);
    if TargetDC=0 then Exit;
    Saved:=SaveDC(TargetDC);Target:=nil;
    try
      Target:=TCanvas.Create;
      Target.Handle:=TargetDC;
      // Own the entire nonclient frame. Letting DefSubclassProc paint it first
      // can expose a stock scrollbar before a later overlay reaches DWM.
      ExcludeClipRect(TargetDC,ClientBounds.Left,ClientBounds.Top,
        ClientBounds.Right,ClientBounds.Bottom);
      Target.Brush.Color:=FBar.Colors.Background;
      Target.FillRect(Rect(0,0,WindowRect.Width,WindowRect.Height));
      Info:=Default(TScrollBarInfo);Info.cbSize:=SizeOf(Info);
      if (GetWindowLongPtr(FList,GWL_STYLE) and WS_VSCROLL<>0) and
        GetScrollBarInfo(FList,Longint(OBJID_VSCROLL),Info) and
        not Info.rcScrollBar.IsEmpty then
      begin
        FBar.SetBounds(Info.rcScrollBar.Left-Origin.X,Info.rcScrollBar.Top-Origin.Y,
          Info.rcScrollBar.Width,Info.rcScrollBar.Height);
        Bounds:=Info.rcScrollBar;
        OffsetRect(Bounds,-WindowRect.Left,-WindowRect.Top);
        FBar.Render(Target,Bounds);
      end;
    finally
      if Target<>nil then begin Target.Handle:=0;Target.Free;end;
      RestoreDC(TargetDC,Saved);
      if DC=0 then ReleaseDC(FList,TargetDC);
    end;
  finally FPainting:=False;end;
end;

procedure TNativeListPresenter.Refresh(const Ppi: Integer);
var R,W: TRect;Count,Height,Page,Top: Integer;Info:TScrollInfo;
begin
  if FUpdating or FInsideScroll or (FList=0) or (FBar=nil) then Exit;
  FUpdating:=True;
  try
    FPpi:=Max(1,Ppi);FBar.ScaleForPPI(FPpi);
    // Retain native scrollbar state and nonclient geometry for keyboard/UIA.
    // Its nonclient surface uses the same renderer as the language picker.
    GetClientRect(FList,R);
    Count:=Max(0,Integer(SendMessage(FList,LB_GETCOUNT,0,0)));
    Height:=Max(1,Integer(SendMessage(FList,LB_GETITEMHEIGHT,0,0)));
    Page:=Max(1,R.Height div Height);
    Top:=Max(0,Integer(SendMessage(FList,LB_GETTOPINDEX,0,0)));
    // Publish the same native scroll state while automatic list painting is
    // disabled. FALSE prevents SetScrollInfo from drawing a stock scrollbar.
    Info:=Default(TScrollInfo);Info.cbSize:=SizeOf(Info);
    Info.fMask:=SIF_RANGE or SIF_PAGE or SIF_POS;
    Info.nMin:=0;Info.nMax:=Max(0,Count-1);Info.nPage:=Page;Info.nPos:=Top;
    SetScrollInfo(FList,SB_VERT,Info,False);
    FBar.Configure(Count,Page,Top);
    if GetWindowRect(FList,W) and ((W.Width<>FRegionWidth) or
      (W.Height<>FRegionHeight) or (FPpi<>FRegionPpi)) then
    begin
      SetWindowRgn(FList,CreateRoundRectRgn(0,0,W.Width+1,W.Height+1,
        MulDiv(GuiPopupCornerRadius*2,FPpi,96),MulDiv(GuiPopupCornerRadius*2,FPpi,96)),True);
      FRegionWidth:=W.Width;FRegionHeight:=W.Height;FRegionPpi:=FPpi;
    end;
    PaintRows;PaintNative;
  finally FUpdating:=False;end;
end;

function TNativeListPresenter.MessageProc(const Msg: UINT; const WParam: WPARAM;
  const LParam: LPARAM): LRESULT;
var P,Origin,Viewport:TPoint;Inside,WasInsideScroll,Move,Down,Up,WasHover: Boolean;
    Page,Count,Top,Saved: Integer;R: TRect;DC:HDC;PS:TPaintStruct;
begin
  if Msg=WM_SETREDRAW then
  begin
    FRedrawEnabled:=WParam<>0;
    Result:=DefSubclassProc(FList,Msg,0,LParam);
    if FRedrawEnabled then Refresh(FPpi);
    Exit;
  end;
  if Msg=WM_ERASEBKGND then begin Result:=1;Exit;end;
  if Msg=WM_PAINT then
  begin
    DC:=BeginPaint(FList,PS);
    try PaintRows(DC);finally EndPaint(FList,PS);end;
    PaintNative;Result:=0;Exit;
  end;
  if Msg=WM_PRINTCLIENT then
  begin PaintRows(HDC(WParam));Result:=0;Exit;end;
  if Msg=WM_NCPAINT then
  begin PaintNative;Result:=0;Exit;end;
  if Msg=WM_PRINT then
  begin
    Result:=0;
    if (LParam and PRF_CHECKVISIBLE<>0) and not IsWindowVisible(FList) then Exit;
    DC:=HDC(WParam);
    if LParam and PRF_CLIENT<>0 then
    begin
      Saved:=SaveDC(DC);
      try
        Origin:=Point(0,0);ClientToScreen(FList,Origin);GetWindowRect(FList,R);
        GetViewportOrgEx(DC,Viewport);
        SetViewportOrgEx(DC,Viewport.X+Origin.X-R.Left,Viewport.Y+Origin.Y-R.Top,nil);
        PaintRows(DC);
      finally RestoreDC(DC,Saved);end;
    end;
    if LParam and PRF_NONCLIENT<>0 then PaintNative(DC);
    Exit;
  end;
  if Msg=WM_NCDESTROY then
  begin
    if FBar<>nil then FBar.CancelPointer;
    RemoveWindowSubclass(FList,NativeListSubclass,NativeUInt(Self));
    Result:=DefSubclassProc(FList,Msg,WParam,LParam);
    FList:=0;FreeAndNil(FRows);FreeAndNil(FBar);Exit;
  end;
  if (FBar<>nil) and ((Msg=WM_CAPTURECHANGED) or (Msg=WM_CANCELMODE) or
    ((Msg=WM_SHOWWINDOW) and (WParam=0))) then
  begin FScrollPointer:=False;FBar.CancelPointer;PaintNative;end;
  if (FBar<>nil) and (Msg=WM_MOUSEWHEEL) then
  begin
    GetClientRect(FList,R);
    Count:=Max(0,Integer(SendMessage(FList,LB_GETCOUNT,0,0)));
    Page:=Max(1,R.Height div Max(1,Integer(SendMessage(FList,LB_GETITEMHEIGHT,0,0))));
    Top:=Integer(SendMessage(FList,LB_GETTOPINDEX,0,0));
    Top:=EnsureRange(Top-WheelScrollLines(SmallInt(HiWord(WParam)),Page,Count,FWheelDelta),0,Max(0,Count-Page));
    SendMessage(FList,LB_SETTOPINDEX,Top,0);Refresh(FPpi);Result:=0;Exit;
  end;
  Move:=(Msg=WM_MOUSEMOVE) or (Msg=WM_NCMOUSEMOVE);
  Down:=(Msg=WM_LBUTTONDOWN) or (Msg=WM_NCLBUTTONDOWN);
  Up:=(Msg=WM_LBUTTONUP) or (Msg=WM_NCLBUTTONUP);
  if (FBar<>nil) and (FBar.Maximum>0) and
    (GetWindowLongPtr(FList,GWL_STYLE) and WS_VSCROLL<>0) and (Move or Down or Up) then
  begin
    P:=Point(SmallInt(LoWord(LParam)),SmallInt(HiWord(LParam)));
    if (Msg=WM_NCMOUSEMOVE) or (Msg=WM_NCLBUTTONDOWN) or (Msg=WM_NCLBUTTONUP) then ScreenToClient(FList,P);
    Inside:=(P.X>=FBar.Left) and (P.X<FBar.Left+FBar.Width) and
      (P.Y>=FBar.Top) and (P.Y<FBar.Top+FBar.Height);
    Dec(P.X,FBar.Left);Dec(P.Y,FBar.Top);WasHover:=FBar.Hovering;
    if Move then FBar.PointerMove(P.X,P.Y,Inside);
    if Inside or FScrollPointer then
    begin
      if Down then begin FScrollPointer:=True;FBar.PointerDown(P.X,P.Y);end;
      if Up then begin FBar.PointerUp(P.X,P.Y);FScrollPointer:=False;end;
      PaintNative;
      Result:=0;Exit;
    end;
    if Move and WasHover then PaintNative;
  end;
  if (Msg=WM_VSCROLL) or (Msg=WM_HSCROLL) then
  begin
    WasInsideScroll:=FInsideScroll;FInsideScroll:=True;
    try Result:=DefSubclassProc(FList,Msg,WParam,LParam);
    finally
      FInsideScroll:=WasInsideScroll;
      // Native tracking can paint its scrollbar directly. Finish that input
      // message with the shared surface, before DWM can present a white bar.
      if not FInsideScroll then Refresh(FPpi);
    end;
    Exit;
  end;
  Result:=DefSubclassProc(FList,Msg,WParam,LParam);
  if FOpening and (Msg=WM_WINDOWPOSCHANGED) and not IsWindowVisible(FList) then
  begin
    // Windows has now positioned and sized its list. Present the complete
    // opaque surface immediately, retaining native selection and capture.
    // An already visible window does not enter AnimateWindow's slide path.
    FOpening:=False;
    ShowWindow(FList,SW_SHOWNOACTIVATE);
    Refresh(FPpi);
  end;
  if (Msg=WM_SHOWWINDOW) and (WParam=0) then FOpening:=False;
  case Msg of
    WM_SIZE,WM_WINDOWPOSCHANGED,WM_SHOWWINDOW,WM_STYLECHANGED,WM_KEYDOWN,
    WM_MOUSEMOVE,WM_NCMOUSEMOVE,WM_MOUSELEAVE,
    LB_SETTOPINDEX,LB_SETCURSEL,LB_ADDSTRING,LB_INSERTSTRING,LB_DELETESTRING,LB_RESETCONTENT:
      Refresh(FPpi);
  end;
end;

end.
