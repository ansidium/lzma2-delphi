unit Lzma2LanguagePicker;

interface

uses System.Classes, System.Types, System.SysUtils, Vcl.Forms, Vcl.Graphics, Vcl.Controls, Lzma2GuiScrollbars;

type
  TLanguagePickerColors = TGuiListColors;
  TLanguageSelection = reference to procedure(const Index: Integer);

function ShowLanguagePicker(const OwnerForm: TForm; const Anchor: TWinControl;
  const Languages: TStrings; const Selected: Integer;
  const SearchHint, EmptyText: string; const Colors: TLanguagePickerColors;
  const SelectedLanguage: TLanguageSelection;
  const ReturnFocus: TProc<Boolean>): TCustomControl;

implementation

uses System.Math, System.StrUtils, Winapi.Windows, Winapi.Messages, Winapi.CommCtrl,
  Vcl.StdCtrls, Vcl.AppEvnts, Lzma2GuiEditHints;

type
  TLanguageScroll = class(TGuiListScrollBar);

  TPickerList = class(TListBox)
  private
    FHoverIndex: Integer;
    FWheelDelta: Integer;
    procedure SetHoverIndex(const Value: Integer);
    procedure CMMouseLeave(var Message: TMessage); message CM_MOUSELEAVE;
  public
    ScrollChanged: TNotifyEvent;
    constructor Create(AOwner: TComponent); override;
    property HoverIndex: Integer read FHoverIndex write SetHoverIndex;
  protected
    procedure WndProc(var Message: TMessage); override;
    procedure MouseMove(Shift: TShiftState; X,Y: Integer); override;
  end;



  TLanguagePopup = class(TCustomControl)
  private
    FSearch: TEdit;
    FList: TPickerList;
    FScroll: TLanguageScroll;
    FAll: TStringList;
    FEmptyText: string;
    FAnchor: TWinControl;
    FColors: TLanguagePickerColors;
    FSelected: Integer;
    FSelectedLanguage: TLanguageSelection;
    FReturnFocus: TProc<Boolean>;
    FEvents: TApplicationEvents;
    FParentColor: TColor;
    procedure FilterChanged(Sender: TObject);
    procedure DrawLanguage(Control: TWinControl; Index: Integer;
      Rect: TRect; State: TOwnerDrawState);
    procedure MouseChoose(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure Keyboard(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure ApplicationMessage(var Msg: TMsg; var Handled: Boolean);
    procedure ApplicationDeactivate(Sender: TObject);
    procedure ApplicationIdle(Sender: TObject; var Done: Boolean);
    procedure ScrollChanged(Sender: TObject);
    procedure ScrollDragged(Sender: TObject);
    procedure Choose(const Keyboard: Boolean=False);
    procedure Dismiss(const ReturnFocus: Boolean; const Keyboard: Boolean=False);
  protected
    procedure Paint; override;
  public
    constructor CreatePicker(const OwnerForm: TForm; const Anchor: TWinControl;
      const Languages: TStrings; const Selected: Integer;
      const SearchHint, EmptyText: string; const Colors: TLanguagePickerColors;
      const SelectedLanguage: TLanguageSelection; const ReturnFocus: TProc<Boolean>);
    destructor Destroy; override;
  end;

constructor TPickerList.Create(AOwner: TComponent);
begin
  inherited;
  FHoverIndex:=-1;
  Cursor:=crHandPoint;
end;

procedure TPickerList.SetHoverIndex(const Value: Integer);
begin
  if FHoverIndex=Value then Exit;
  FHoverIndex:=Value;
  if Value<0 then Cursor:=crDefault else Cursor:=crHandPoint;
  Invalidate;
end;

procedure TPickerList.MouseMove(Shift: TShiftState; X,Y: Integer);
begin
  inherited;
  SetHoverIndex(ItemAtPos(Point(X,Y),True));
end;

procedure TPickerList.CMMouseLeave(var Message: TMessage);
begin
  inherited;
  SetHoverIndex(-1);
end;

procedure TPickerList.WndProc(var Message: TMessage);
var P: TPoint;
    Lines: UINT;
    Steps, PageSize: Integer;
begin
  if Message.Msg=WM_MOUSEWHEEL then
  begin
    // The custom scrollbar hides WS_VSCROLL, so the native listbox no longer
    // handles wheel input. Keep partial deltas and honor the Windows setting.
    Inc(FWheelDelta,SmallInt(HiWord(Message.WParam)));
    Steps:=FWheelDelta div WHEEL_DELTA;
    Dec(FWheelDelta,Steps*WHEEL_DELTA);
    Lines:=3;
    SystemParametersInfo(SPI_GETWHEELSCROLLLINES,0,@Lines,0);
    PageSize:=Max(1,ClientHeight div ItemHeight);
    if Lines=WHEEL_PAGESCROLL then Lines:=PageSize;
    if Steps<>0 then
      TopIndex:=EnsureRange(TopIndex-Steps*Integer(Min(Lines,UINT(Items.Count))),
        0,Max(0,Items.Count-PageSize));
    Message.Result:=0;
  end
  else inherited;
  case Message.Msg of
    WM_SIZE, WM_MOUSEWHEEL, WM_VSCROLL, WM_KEYDOWN:
    begin
      ShowScrollBar(Handle, SB_VERT, False);
      GetCursorPos(P);P:=ScreenToClient(P);
      if PtInRect(ClientRect,P) then SetHoverIndex(ItemAtPos(P,True)) else SetHoverIndex(-1);
      if Assigned(ScrollChanged) then ScrollChanged(Self);
    end;
  end;
end;


constructor TLanguagePopup.CreatePicker(const OwnerForm: TForm; const Anchor: TWinControl;
  const Languages: TStrings; const Selected: Integer;
  const SearchHint, EmptyText: string; const Colors: TLanguagePickerColors;
  const SelectedLanguage: TLanguageSelection; const ReturnFocus: TProc<Boolean>);
var I, ListHeight, Rows, RowHeight: Integer;
    P: TPoint;
  function S(const V: Integer): Integer;
  begin Result := MulDiv(V, OwnerForm.PixelsPerInch, 96); end;
begin
  inherited Create(OwnerForm);
  Visible := False;
  Parent := OwnerForm;
  ParentFont := True;
  StyleElements := [];
  ControlStyle := ControlStyle + [csOpaque];
  DoubleBuffered := True;
  Color := Colors.Background;
  FParentColor := OwnerForm.Color;
  FColors := Colors;
  FEmptyText := EmptyText;
  FAnchor := Anchor;
  FSelected := Selected;
  FSelectedLanguage := SelectedLanguage;
  FReturnFocus := ReturnFocus;
  P := OwnerForm.ScreenToClient(Anchor.ClientToScreen(Point(Anchor.Width, Anchor.Height)));
  Width := Min(S(280), Max(S(160), OwnerForm.ClientWidth-S(16)));
  RowHeight := S(GuiPopupRowHeight);
  Rows := EnsureRange((OwnerForm.ClientHeight-P.Y-S(60)) div RowHeight,1,7);
  ListHeight := Rows*RowHeight;
  Height := S(52)+ListHeight;
  FAll := TStringList.Create;
  for I := 0 to Languages.Count-1 do FAll.AddObject(Languages[I], TObject(NativeInt(I)));
  FSearch := TEdit.Create(Self);
  FSearch.Parent := Self;
  FSearch.ParentFont := True;
  FSearch.AutoSize := False;
  FSearch.SetBounds(S(16),S(10),Width-S(32),S(26));
  FSearch.BorderStyle := bsNone;
  FSearch.Color := Colors.Background;
  FSearch.Font.Color := Colors.Text;
  FSearch.StyleElements := [];
  TGuiEditHint.CreateForEdit(FSearch,Colors.Muted);
  FSearch.TextHint := SearchHint;
  FSearch.Hint := SearchHint;
  FSearch.ShowHint := True;
  FSearch.OnChange := FilterChanged;
  FSearch.OnKeyDown := Keyboard;
  FList := TPickerList.Create(Self);
  FList.Parent := Self;
  FList.ParentFont := True;
  FList.SetBounds(S(8),S(44),Width-S(36),ListHeight);
  FList.BorderStyle := bsNone;
  FList.Ctl3D := False;
  FList.Style := lbOwnerDrawFixed;
  FList.ItemHeight := RowHeight;
  FList.IntegralHeight := False;
  FList.Color := Colors.Background;
  FList.Font.Color := Colors.Text;
  FList.StyleElements := [];
  FList.OnDrawItem := DrawLanguage;
  FList.OnMouseUp := MouseChoose;
  FList.OnKeyDown := Keyboard;
  FList.ScrollChanged := ScrollChanged;
  FScroll := TLanguageScroll.Create(Self);
  FScroll.Parent := Self;
  FScroll.SetBounds(Width-S(22),S(44),S(14),ListHeight);
  FScroll.Colors := Colors;
  FScroll.Changed := ScrollDragged;
  FEvents := TApplicationEvents.Create(Self);
  FEvents.OnMessage := ApplicationMessage;
  FEvents.OnDeactivate := ApplicationDeactivate;
  FEvents.OnIdle := ApplicationIdle;
  FilterChanged(nil);
  if (Selected>=0) and (Selected<FList.Count) then FList.ItemIndex := Selected;
  ScrollChanged(nil);
  Left := EnsureRange(P.X-Width,S(8),Max(S(8),OwnerForm.ClientWidth-Width-S(8)));
  Top := EnsureRange(P.Y,S(8),Max(S(8),OwnerForm.ClientHeight-Height-S(8)));
  BringToFront;
  Show;
  FSearch.SetFocus;
  SendMessage(FSearch.Handle,EM_SETCUEBANNER,1,LPARAM(PChar(SearchHint)));
end;

destructor TLanguagePopup.Destroy;
begin
  FreeAndNil(FEvents);
  FSelectedLanguage := nil;
  FReturnFocus := nil;
  FAll.Free;
  inherited;
end;

procedure TLanguagePopup.Paint;
var R: TRect;
begin
  Canvas.Brush.Color := FParentColor;
  Canvas.FillRect(ClientRect);
  Canvas.Pen.Style := psClear;
  Canvas.Brush.Color := FColors.Background;
  Canvas.RoundRect(0,0,Width,Height,ScaleValue(8),ScaleValue(8));
  Canvas.Pen.Style := psSolid;
  if FList.Count=0 then
  begin
    Canvas.Font.Assign(Font);
    Canvas.Font.Color := FColors.Muted;
    Canvas.Brush.Style := bsClear;
    R := Rect(ScaleValue(16),ScaleValue(48),Width-ScaleValue(16),ScaleValue(80));
    DrawText(Canvas.Handle,PChar(FEmptyText),-1,R,DT_SINGLELINE or DT_VCENTER or DT_NOPREFIX);
    Canvas.Brush.Style := bsSolid;
  end;
end;

procedure TLanguagePopup.FilterChanged(Sender: TObject);
var I: Integer;
    Query: string;
begin
  if FList=nil then Exit;
  Query := Trim(FSearch.Text);
  FList.Items.BeginUpdate;
  try
    FList.HoverIndex:=-1;
    FList.Clear;
    for I := 0 to FAll.Count-1 do
      if (Query='') or (FindNLSStringEx(LOCALE_NAME_INVARIANT,
        FIND_FROMSTART or NORM_IGNORECASE or NORM_IGNORENONSPACE,
        PChar(FAll[I]),Length(FAll[I]),PChar(Query),Length(Query),nil,nil,nil,0)>=0) then
        FList.Items.AddObject(FAll[I],FAll.Objects[I]);
    if FList.Count>0 then FList.ItemIndex := 0;
    if (Query='') and (FSelected>=0) and (FSelected<FList.Count) then FList.ItemIndex := FSelected;
  finally FList.Items.EndUpdate; end;
  FList.Visible := FList.Count>0;
  ShowScrollBar(FList.Handle,SB_VERT,False);
  ScrollChanged(nil);
  Invalidate;
end;

procedure TLanguagePopup.DrawLanguage(Control: TWinControl; Index: Integer;
  Rect: TRect; State: TOwnerDrawState);
var
  ListCanvas: TCanvas;
  CornerDiameter: Integer;
begin
  ListCanvas := FList.Canvas;
  ListCanvas.Brush.Color := FColors.Background;
  ListCanvas.FillRect(Rect);
  if (odSelected in State) or (Index = FList.HoverIndex) then
  begin
    ListCanvas.Brush.Color := FColors.Hover;
    if odSelected in State then
      ListCanvas.Brush.Color := FColors.Selection;
    CornerDiameter := ScaleValue(8);
    ListCanvas.Pen.Style := psClear;
    ListCanvas.RoundRect(Rect.Left, Rect.Top, Rect.Right, Rect.Bottom,
      CornerDiameter, CornerDiameter);
    ListCanvas.Pen.Style := psSolid;
  end;
  ListCanvas.Font.Assign(FList.Font);
  ListCanvas.Font.Color := FColors.Text;
  Inc(Rect.Left,ScaleValue(8));
  DrawText(ListCanvas.Handle,PChar(FList.Items[Index]),-1,Rect,
    DT_SINGLELINE or DT_VCENTER or DT_LEFT or DT_NOPREFIX);
end;

procedure TLanguagePopup.Dismiss(const ReturnFocus: Boolean; const Keyboard: Boolean);
begin
  Hide;
  if ReturnFocus and FAnchor.CanFocus then
  begin
    if Assigned(FReturnFocus) then FReturnFocus(Keyboard) else FAnchor.SetFocus;
  end;
end;

procedure TLanguagePopup.Choose(const Keyboard: Boolean);
var Selected: Integer;
begin
  if FList.ItemIndex<0 then Exit;
  Selected := Integer(NativeInt(FList.Items.Objects[FList.ItemIndex]));
  Dismiss(True,Keyboard);
  if Assigned(FSelectedLanguage) then FSelectedLanguage(Selected);
end;

procedure TLanguagePopup.MouseChoose(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X,Y: Integer);
var Index: Integer;
begin
  Index := FList.ItemAtPos(Point(X,Y),True);
  if (Button=mbLeft) and (Index>=0) then begin FList.ItemIndex:=Index; Choose; end;
end;

procedure TLanguagePopup.Keyboard(Sender: TObject; var Key: Word; Shift: TShiftState);
var Index: Integer;
begin
  case Key of
    VK_ESCAPE: begin Dismiss(True,True); Key:=0; end;
    VK_RETURN: begin Choose(True); Key:=0; end;
    VK_UP,VK_DOWN,VK_PRIOR,VK_NEXT:
      begin
        Index:=FList.ItemIndex;
        case Key of
          VK_UP: Dec(Index);
          VK_DOWN: Inc(Index);
          VK_PRIOR: Dec(Index,7);
          VK_NEXT: Inc(Index,7);
        end;
        if FList.Count>0 then FList.ItemIndex:=EnsureRange(Index,0,FList.Count-1);
        ScrollChanged(nil);
        Key:=0;
      end;
  end;
end;

procedure TLanguagePopup.ApplicationMessage(var Msg: TMsg; var Handled: Boolean);
begin
  if not Visible then Exit;
  case Msg.message of
    WM_MOUSEWHEEL:
      if IsChild(Handle,Msg.hwnd) and (Msg.hwnd<>FList.Handle) then
      begin
        FList.Perform(WM_MOUSEWHEEL,Msg.wParam,Msg.lParam);
        Handled:=True;
      end;
    WM_LBUTTONDOWN,WM_RBUTTONDOWN,WM_MBUTTONDOWN,WM_NCLBUTTONDOWN,WM_NCRBUTTONDOWN:
      if (Msg.hwnd<>Handle) and not IsChild(Handle,Msg.hwnd) and
        (Msg.hwnd<>FAnchor.Handle) and not IsChild(FAnchor.Handle,Msg.hwnd) then Dismiss(False);
  end;
end;

procedure TLanguagePopup.ApplicationDeactivate(Sender: TObject);
begin
  if Visible then Dismiss(False);
end;

procedure TLanguagePopup.ApplicationIdle(Sender: TObject; var Done: Boolean);
var Focus: HWND;
begin
  if not Visible then Exit;
  Focus:=GetFocus;
  if (Focus<>Handle) and not IsChild(Handle,Focus) then Dismiss(False);
end;

procedure TLanguagePopup.ScrollChanged(Sender: TObject);
begin
  if FScroll=nil then Exit;
  FScroll.Configure(FList.Count,Max(1,FList.ClientHeight div FList.ItemHeight),FList.TopIndex);
end;

procedure TLanguagePopup.ScrollDragged(Sender: TObject);
begin
  FList.TopIndex:=FScroll.Position;
  FScroll.Invalidate;
end;

function ShowLanguagePicker(const OwnerForm: TForm; const Anchor: TWinControl;
  const Languages: TStrings; const Selected: Integer;
  const SearchHint,EmptyText: string; const Colors: TLanguagePickerColors;
  const SelectedLanguage: TLanguageSelection;
  const ReturnFocus: TProc<Boolean>): TCustomControl;
begin
  Result:=TLanguagePopup.CreatePicker(OwnerForm,Anchor,Languages,Selected,
    SearchHint,EmptyText,Colors,SelectedLanguage,ReturnFocus);
end;

end.
