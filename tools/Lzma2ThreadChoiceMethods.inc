const
  WM_BEGIN_THREAD_INPUT=WM_APP+$2A1;

constructor TThreadChoiceCombo.Create(AOwner: TComponent);
begin
  inherited;
  Style:=csDropDown;
  AutoComplete:=False;
end;

procedure TThreadChoiceCombo.CreateParams(var Params: TCreateParams);
begin
  inherited;
  // Windows supports an editable, owner-drawn combo. Keep its native edit,
  // keyboard and accessibility provider rather than opening another form.
  Params.Style:=Params.Style or CBS_OWNERDRAWFIXED or WS_CLIPCHILDREN;
end;

procedure TThreadChoiceCombo.CreateWnd;
var WasUpdating:Boolean;
begin
  WasUpdating:=FUpdating;FUpdating:=True;
  try
    inherited;
    Perform(CB_SETITEMHEIGHT,0,ScaleValue(GuiPopupRowHeight));
    LayoutEdit;
  finally FUpdating:=WasUpdating;end;
end;

procedure TThreadChoiceCombo.LayoutEdit;
var Info:TComboBoxInfo;H:Integer;
begin
  if not HandleAllocated then Exit;
  Info.cbSize:=SizeOf(Info);
  if not GetComboBoxInfo(Handle,Info) or (Info.hwndItem=0) then Exit;
  H:=GuiNativeEditHeight(Font);
  SetWindowPos(Info.hwndItem,0,ScaleValue(12),(ClientHeight-H+1) div 2,
    Max(1,ClientWidth-ScaleValue(12+UiOptionArrowWidth)),H,SWP_NOZORDER or SWP_NOACTIVATE);
  SendMessage(Info.hwndItem,EM_SETMARGINS,EC_LEFTMARGIN or EC_RIGHTMARGIN,0);
end;

procedure TThreadChoiceCombo.ChangeScale(M,D:Integer;isDpiChange:Boolean);
begin
  inherited;
  if HandleAllocated then Perform(CB_SETITEMHEIGHT,0,ScaleValue(GuiPopupRowHeight));
  LayoutEdit;
end;

procedure TThreadChoiceCombo.Configure(const ProcessorCount: Integer;
  const AutoCaption,OtherCaption,ManualFormat: string);
var I,Previous: Integer;Pending:string;PendingAuto:Boolean;
begin
  Previous:=FState.RequestedWorkers;Pending:=Text;
  PendingAuto:=SameText(Trim(Pending),FAutoCaption);
  FState:=TThreadChoiceState.Create(ProcessorCount,Previous);
  FPopupSelection:=-1;FUpdating:=True;
  Items.BeginUpdate;
  try
    Items.Clear;Items.Add(AutoCaption);
    for I:=1 to ProcessorCount do Items.Add(IntToStr(I));
    Items.Add(OtherCaption);
    FAutoCaption:=AutoCaption;FOtherCaption:=OtherCaption;
    if PendingAuto then Pending:=AutoCaption;
    if FEditing then Text:=Pending;
  finally Items.EndUpdate;FUpdating:=False;end;
  FConfigured:=True;
  RestoreSelection;
end;

function TThreadChoiceCombo.GetRequestedWorkers: Integer;
begin Result:=FState.RequestedWorkers;end;

function TThreadChoiceCombo.CommittedText:string;
begin
  if RequestedWorkers=0 then Result:=FAutoCaption
  else Result:=IntToStr(RequestedWorkers);
end;

function TThreadChoiceCombo.TryInput(out Value:Integer):Boolean;
begin
  if SameText(Trim(Text),FAutoCaption) then begin Value:=0;Exit(True);end;
  Result:=TryStrToInt(Trim(Text),Value) and (Value>0);
end;

function TThreadChoiceCombo.GetInputValid:Boolean;
var Value:Integer;
begin Result:=TryInput(Value);end;

function TThreadChoiceCombo.InputInvalid:Boolean;
begin Result:=not InputValid;end;

procedure TThreadChoiceCombo.RestoreSelection;
begin
  if FEditing or (Items.Count<>FState.ChoiceCount) then Exit;
  FUpdating:=True;
  try
    Items[FState.CustomIndex]:=FOtherCaption;
    ItemIndex:=FState.ChoiceIndex;
    Text:=CommittedText;
  finally FUpdating:=False;end;
  if not Focused then begin SelStart:=Length(Text);SelLength:=0;end;
  Invalidate;
end;

procedure TThreadChoiceCombo.SetRequestedWorkers(const Value: Integer);
begin
  FState.RequestedWorkers:=Value;FEditing:=False;
  FRequestPending:=False;RestoreSelection;
end;

procedure TThreadChoiceCombo.UpdateCaptions(const AutoCaption,OtherCaption,ManualFormat:string);
var Pending:string;PendingAuto:Boolean;
begin
  Pending:=Text;PendingAuto:=SameText(Trim(Pending),FAutoCaption);
  FAutoCaption:=AutoCaption;FOtherCaption:=OtherCaption;
  if PendingAuto then Pending:=AutoCaption;
  FUpdating:=True;
  try
    if Items.Count>0 then Items[0]:=AutoCaption;
    if FEditing then Text:=Pending;
  finally FUpdating:=False;end;
  RestoreSelection;
end;

procedure TThreadChoiceCombo.NotifyCommit;
begin
  FNotifying:=True;
  try inherited Select;finally FNotifying:=False;end;
end;

function TThreadChoiceCombo.CommitInput(const NotifyChange:Boolean):Boolean;
var Value,Previous:Integer;
begin
  Result:=True;
  if not FConfigured then Exit;
  Result:=TryInput(Value);
  if not Result then begin Invalidate;Exit;end;
  Previous:=RequestedWorkers;FState.RequestedWorkers:=Value;
  FEditing:=False;RestoreSelection;
  if NotifyChange and (Previous<>Value) then NotifyCommit;
end;

procedure TThreadChoiceCombo.Change;
var PendingChanged:Boolean;
begin
  if FUpdating or FInPopup then Exit;
  PendingChanged:=not SameText(Text,CommittedText);
  // Native focus/selection refreshes may set the same text again. They are
  // not user edits and must not invalidate Auto or erase benchmark results.
  if not FNotifying and not FEditing and not PendingChanged then Exit;
  Inc(FChangeSerial);
  if not FNotifying then FEditing:=PendingChanged;
  Invalidate;
  inherited;
end;

procedure TThreadChoiceCombo.ComboWndProc(var Message:TMessage;ComboWnd:HWND;
  ComboProc:TWindowProcPtr);
var Before:UInt64;
begin
  Before:=FChangeSerial;
  inherited;
  // Native WM_SETTEXT does not promise a CBN_EDITCHANGE notification. Observe
  // both edit/combobox text paths so keyboard, paste and accessibility agree.
  if (Message.Msg=WM_SETTEXT) and (ComboWnd=EditHandle) and FConfigured and
    (FTextUpdateDepth=0) and not FUpdating and not FInPopup and
    (FChangeSerial=Before) then Change;
end;

procedure TThreadChoiceCombo.DoExit;
begin
  if not FInPopup then CommitInput;
  inherited;
  if not FInPopup then begin SelStart:=Length(Text);SelLength:=0;end;
end;

procedure TThreadChoiceCombo.KeyDown(var Key:Word;Shift:TShiftState);
begin
  if not DroppedDown then
    case Key of
      VK_RETURN:begin CommitInput;Key:=0;Exit;end;
      VK_ESCAPE:
        if FEditing then
        begin
          FEditing:=False;RestoreSelection;SelectAll;
          FNotifying:=True;
          try inherited Change;finally FNotifying:=False;end;
          Key:=0;Exit;
        end;
    end;
  inherited;
end;

procedure TThreadChoiceCombo.KeyPress(var Key:Char);
var Selected:Integer;
begin
  if DroppedDown and (Key=#13) then
  begin
    // VCL closes the list with CB_SHOWDROPDOWN, which reports cancellation.
    // Save the highlighted row before that native close, then accept it once
    // the popup transaction has restored its previous inline-editor state.
    Selected:=ItemIndex;DroppedDown:=False;
    if Selected>=0 then CommitSelection(Selected);
    Key:=#0;Exit;
  end;
  // Let VCL finish an open native popup on Enter/Esc before suppressing
  // those characters in the inline numeric editor.
  if not DroppedDown and ((Key=#13) or (Key=#27)) then begin Key:=#0;Exit;end;
  inherited;
end;

procedure TThreadChoiceCombo.CommitSelection(const Index:Integer);
var Previous:Integer;WasEditing:Boolean;
begin
  Previous:=RequestedWorkers;WasEditing:=FEditing;
  if FState.IsNumericChoice(Index) then
  begin
    FEditing:=False;FState.SelectNumericChoice(Index);RestoreSelection;
    if WasEditing or (Previous<>RequestedWorkers) then NotifyCommit;
  end
  else if Index=FState.CustomIndex then
  begin
    FEditing:=False;RestoreSelection;
    if not FRequestPending then
    begin
      FRequestPending:=True;
      // Finish the native popup transaction before focusing its inline edit.
      PostMessage(Handle,WM_BEGIN_THREAD_INPUT,0,0);
    end;
  end;
end;

procedure TThreadChoiceCombo.Select;
begin
  if not FUpdating and not FInPopup then CommitSelection(ItemIndex);
end;

procedure TThreadChoiceCombo.DestroyWnd;
begin
  FInPopup:=False;FRequestPending:=False;FPopupCancelled:=False;FPopupSelection:=-1;
  inherited;
end;

procedure TThreadChoiceCombo.WndProc(var Message:TMessage);
var Code,Key:Word;Selected,Value:Integer;Pending:string;Before:UInt64;
begin
  if Message.Msg=WM_SETTEXT then
  begin
    Before:=FChangeSerial;Inc(FTextUpdateDepth);
    try inherited WndProc(Message);finally Dec(FTextUpdateDepth);end;
    if (FTextUpdateDepth=0) and FConfigured and not FUpdating and not FInPopup and
      (FChangeSerial=Before) then Change;
    Exit;
  end;
  if Message.Msg=WM_BEGIN_THREAD_INPUT then
  begin
    if not FRequestPending then Exit;
    FRequestPending:=False;
    if not CanFocus or DroppedDown then Exit;
    Value:=RequestedWorkers;
    if Value<1 then Value:=FState.ProcessorCount;
    FEditing:=True;FUpdating:=True;
    try Text:=IntToStr(Value);finally FUpdating:=False;end;
    SetFocus;SelectAll;Invalidate;
    inherited Change;
    Message.Result:=0;Exit;
  end;
  if (Message.Msg=CM_DIALOGKEY) and Focused and not DroppedDown and
    ((Message.WParam=VK_RETURN) or ((Message.WParam=VK_ESCAPE) and FEditing)) then
  begin
    Key:=Word(Message.WParam);KeyDown(Key,[]);
    Message.Result:=1;Exit;
  end;
  if Message.Msg=CN_COMMAND then
  begin
    Code:=HiWord(Message.WParam);
    case Code of
      CBN_DROPDOWN:
        begin
          FPopupText:=Text;FPopupEditing:=FEditing;
          FInPopup:=True;FPopupCancelled:=False;FPopupSelection:=-1;
        end;
      CBN_SELCHANGE:if FInPopup and not FPopupCancelled then FPopupSelection:=ItemIndex;
      CBN_SELENDOK:begin FPopupCancelled:=False;FPopupSelection:=ItemIndex;end;
      CBN_SELENDCANCEL:begin FPopupCancelled:=True;FPopupSelection:=-1;end;
      CBN_CLOSEUP:
        begin
          if FPopupCancelled then Selected:=-1 else Selected:=FPopupSelection;
          FPopupSelection:=-1;
          inherited WndProc(Message);
          FInPopup:=False;
          if Selected>=0 then CommitSelection(Selected)
          else
          begin
            FEditing:=FPopupEditing;Pending:=FPopupText;
            if FEditing then
            begin FUpdating:=True;try Text:=Pending;finally FUpdating:=False;end;end
            else RestoreSelection;
          end;
          Exit;
        end;
    end;
  end;
  inherited WndProc(Message);
  case Message.Msg of
    WM_SIZE,CM_FONTCHANGED:LayoutEdit;
  end;
end;
