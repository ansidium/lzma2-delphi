function TMainForm.BenchmarkBusy: Boolean;
begin
  Result := (FBenchBackend<>nil) and not FBenchBackend.Snapshot.Finished;
end;

function TMainForm.BenchmarkConfig: TBenchmarkConfig;
var Index: Integer;
begin
  Result := Default(TBenchmarkConfig);
  Index := EnsureRange(FBenchDictionary.ItemIndex,0,High(BenchmarkDictionaryMb));
  Result.DictionarySize := UInt64(BenchmarkDictionaryMb[Index]) shl 20;
  Result.MemoryLimit := GuiMemoryBudget;
  Result.Workers := FBenchThreads.RequestedWorkers;
  if Result.Workers<1 then
    Result.Workers := TLzmaBenchmark.AutoWorkers(Result.DictionarySize,Result.MemoryLimit,GuiProcessorCount);
  Result.Passes := BenchmarkPassCounts[EnsureRange(FBenchPasses.ItemIndex,0,High(BenchmarkPassCounts))];
  Result.PhaseMilliseconds := GuiBenchmarkDefault('phaseMilliseconds');
end;

procedure TMainForm.LayoutBenchmark;
const
  MemoryTop = UiFieldTop + UiOptionHeight + 8;
  TableTop = MemoryTop + 20 + 12;
  FirstRowTop = TableTop + 40;
  OverallTop = FirstRowTop + 116;
var
  W, Gap, SettingWidth, Side, Column, Metric, RowTop, ActionLeft: Integer;
  OperationWidth, RowLabelWidth, FirstValue, CellLeft, CellRight, StatusWidth: Integer;
  ActionWidth, CopyWidth: Integer;
begin
  W := FMainPanel.ClientWidth;
  Gap := ScaleValue(UiGap);
  FBenchmarkPanel.SetBounds(0, ScaleValue(UiModeTop), W, FMainPanel.ClientHeight-ScaleValue(UiModeTop));
  SettingWidth := (W-Gap*2) div 3;
  FBenchSettingLabels[0].SetBounds(0, 0, SettingWidth, ScaleValue(UiLabelHeight));
  FBenchSettingLabels[1].SetBounds(SettingWidth+Gap, 0, SettingWidth, ScaleValue(UiLabelHeight));
  FBenchSettingLabels[2].SetBounds(W-SettingWidth, 0, SettingWidth, ScaleValue(UiLabelHeight));
  FBenchDictionary.SetBounds(0, ScaleValue(UiFieldTop), SettingWidth, ScaleValue(UiOptionHeight));
  FBenchThreads.SetBounds(SettingWidth+Gap, ScaleValue(UiFieldTop), SettingWidth, ScaleValue(UiOptionHeight));
  FBenchPasses.SetBounds(W-SettingWidth, ScaleValue(UiFieldTop), SettingWidth, ScaleValue(UiOptionHeight));
  FBenchMemory.SetBounds(0, ScaleValue(MemoryTop), W, ScaleValue(20));

  OperationWidth := ScaleValue(96);
  RowLabelWidth := ScaleValue(68);
  for Side := 0 to 1 do
  begin
    OperationWidth := Max(OperationWidth, CaptionWidth(FBenchHeadings[Side].Caption,FBenchHeadings[Side].Font)+ScaleValue(12));
    for Column := 0 to 1 do
      RowLabelWidth := Max(RowLabelWidth, CaptionWidth(FBenchColumns[Side,Column].Caption,FBenchColumns[Side,Column].Font)+ScaleValue(12));
  end;
  FirstValue := Min(W div 2, OperationWidth+RowLabelWidth);
  OperationWidth := Min(OperationWidth, FirstValue-ScaleValue(60));
  FBenchTableHeader.SetBounds(0, ScaleValue(TableTop), FirstValue, ScaleValue(36));
  FBenchTableHeader.Layout := tlCenter;

  for Metric := 0 to 3 do
  begin
    CellLeft := FirstValue+MulDiv(Metric, W-FirstValue, 4);
    CellRight := FirstValue+MulDiv(Metric+1, W-FirstValue, 4);
    FBenchMetricLabels[0,Metric].Visible := True;
    FBenchMetricLabels[0,Metric].Alignment := taRightJustify;
    FBenchMetricLabels[0,Metric].WordWrap := True;
    FBenchMetricLabels[0,Metric].SetBounds(CellLeft, ScaleValue(TableTop),
      CellRight-CellLeft-ScaleValue(6), ScaleValue(36));
    FBenchMetricLabels[1,Metric].Visible := False;
    for Side := 0 to 1 do
      for Column := 0 to 1 do
        FBenchValues[Side,Column,Metric].SetBounds(CellLeft, ScaleValue(FirstRowTop+Side*56+Column*24),
          CellRight-CellLeft-ScaleValue(6), ScaleValue(24));
  end;
  for Side := 0 to 1 do
  begin
    RowTop := ScaleValue(FirstRowTop+Side*56);
    FBenchHeadings[Side].SetBounds(0, RowTop, OperationWidth-ScaleValue(8), ScaleValue(48));
    FBenchHeadings[Side].Layout := tlCenter;
    for Column := 0 to 1 do
    begin
      FBenchColumns[Side,Column].Alignment := taLeftJustify;
      FBenchColumns[Side,Column].Layout := tlCenter;
      FBenchColumns[Side,Column].SetBounds(OperationWidth, RowTop+ScaleValue(Column*24),
        FirstValue-OperationWidth-ScaleValue(6), ScaleValue(24));
    end;
  end;

  FBenchOverallTitle.SetBounds(0, ScaleValue(OverallTop), W div 2, ScaleValue(28));
  FBenchOverall.SetBounds(W div 2, ScaleValue(OverallTop), W-W div 2-ScaleValue(6), ScaleValue(28));
  ActionWidth := Max(ScaleValue(152), Max(CaptionWidth(FBenchStart.Caption,FBenchStart.Font),
    CaptionWidth(FBenchStop.Caption,FBenchStop.Font))+ScaleValue(24));
  CopyWidth := Max(ScaleValue(120), CaptionWidth(FBenchCopy.Caption,FBenchCopy.Font)+ScaleValue(24));
  ActionLeft := W-ActionWidth;
  FBenchStart.SetBounds(ActionLeft, FBenchmarkPanel.ClientHeight-ScaleValue(UiActionInset+UiOptionHeight),
    ActionWidth, ScaleValue(UiOptionHeight));
  FBenchStop.SetBounds(ActionLeft, FBenchStart.Top, ActionWidth, FBenchStart.Height);
  FBenchCopy.SetBounds(ActionLeft-CopyWidth-ScaleValue(12), FBenchStart.Top, CopyWidth, FBenchStart.Height);
  StatusWidth := ActionLeft-Gap;
  if FBenchCopy.Visible then StatusWidth := FBenchCopy.Left-Gap;
  FBenchStateLabel.SetBounds(0, FBenchStart.Top, Max(0,StatusWidth), FBenchStart.Height div 2);
  FBenchStateLabel.Layout := tlCenter;
  FBenchProgressLabel.SetBounds(0, FBenchStart.Top+FBenchStateLabel.Height, FBenchStateLabel.Width, FBenchStart.Height-FBenchStateLabel.Height);
  FBenchProgressLabel.Layout := tlCenter;
end;

procedure TMainForm.ApplyBenchmarkLanguage;
var Side,Column,Metric,Index,I: Integer;
begin
  if FBenchmarkPanel=nil then Exit;
  FBenchSettingLabels[0].Caption := TextOf('Dictionary');
  FBenchSettingLabels[1].Caption := TextOf('Threads');
  FBenchSettingLabels[2].Caption := TextOf('Passes');
  FBenchTableHeader.Caption := TextOf('Operation');
  FBenchHeadings[0].Caption := TextOf('Compression');
  FBenchHeadings[1].Caption := TextOf('Extraction');
  for Side := 0 to 1 do
  begin
    for Column := 0 to 1 do
      if Column=0 then FBenchColumns[Side,Column].Caption := TextOf('Current')
      else FBenchColumns[Side,Column].Caption := TextOf('Average');
    for Metric := 0 to 3 do
      case Metric of
        0: FBenchMetricLabels[Side,Metric].Caption := TextOf('Speed, KiB/s');
        1: FBenchMetricLabels[Side,Metric].Caption := TextOf('CPU, %');
        2: FBenchMetricLabels[Side,Metric].Caption := 'R/U, MIPS';
        3: FBenchMetricLabels[Side,Metric].Caption := TextOf('Rating, MIPS');
      end;
  end;
  Index := FBenchDictionary.ItemIndex;
  for I := 0 to High(BenchmarkDictionaryMb) do FBenchDictionary.Items[I] := DictionaryCaption(BenchmarkDictionaryMb[I]);
  FBenchDictionary.ItemIndex := Index;
  FBenchStart.Caption := TextOf('Start benchmark');
  FBenchStop.Caption := TextOf('Stop');
  FBenchCopy.Caption := TextOf('Copy');
  FBenchOverallTitle.Caption := TextOf('Total rating');
  FBenchMemory.Hint := TextOf('LZMA. Independent workers. 7-Zip rating formulas; R/U is the CPU-normalized rating.');
  BenchmarkSettingsChanged(nil);
end;

procedure TMainForm.BenchmarkSettingsChanged(Sender: TObject);
var Config: TBenchmarkConfig;
    Required: UInt64;
    AutoCaption,RequiredCaption: string;
    Admitted: Boolean;
begin
  if (FBenchThreads=nil) or BenchmarkBusy then Exit;
  Config := BenchmarkConfig;
  AutoCaption := Format(TextOf('Auto (up to %d)'),
    [TLzmaBenchmark.AutoWorkers(Config.DictionarySize,Config.MemoryLimit,GuiProcessorCount)]);
  FBenchThreads.UpdateCaptions(AutoCaption,TextOf('Other...'),TextOf('Manual: %d'));
  try
    Required := TLzmaBenchmark.RequiredMemory(Config);
    RequiredCaption:=GuiFormatBytes(Required,FLanguage);
    Admitted:=Required<=Config.MemoryLimit;
  except
    on E:EArgumentException do
    begin
      // A valid positive manual count may exceed UInt64 memory arithmetic.
      // Keep the request, show admission failure, and disable the operation.
      RequiredCaption:='> '+GuiFormatBytes(Config.MemoryLimit,FLanguage);
      Admitted:=False;
    end;
  end;
  FBenchMemory.Caption := Format(TextOf('Memory: %s / %s'),
    [RequiredCaption,GuiFormatBytes(Config.MemoryLimit,FLanguage)]);
  if Sender<>nil then FBenchLast:=Default(TBenchmarkSnapshot);
  RenderBenchmark;
  SetPanelButtonEnabled(FBenchCopy,FBenchLast.CompletedPasses>0,False);
  SetPanelButtonEnabled(FBenchStart,(FTask=nil) and Admitted and FBenchThreads.InputValid,True);
  if not Admitted then
  begin
    FBenchStateLabel.Caption := TextOf('Reduce dictionary size or worker count');
    FBenchStateLabel.Font.Color := UiAccentHover;
  end;
end;

procedure TMainForm.SetBenchmarkBusy(const Busy: Boolean);
begin
  FLanguageButton.Enabled := not Busy;
  FAboutButton.Enabled := not Busy;
  FCompressModeButton.Enabled := not Busy;
  FDecompressModeButton.Enabled := not Busy;
  FBenchmarkModeButton.Enabled := not Busy;
  FBenchDictionary.Enabled := not Busy;
  FBenchThreads.Enabled := not Busy;
  FBenchPasses.Enabled := not Busy;
  FBenchStart.Visible := not Busy;
  FBenchStop.Visible := Busy;
  FBenchStop.Caption := TextOf('Stop');
  SetPanelButtonEnabled(FBenchStop,Busy,False);
  SetPanelButtonEnabled(FBenchCopy,not Busy and (FBenchLast.CompletedPasses>0),False);
  UpdateModeButtons;
end;

procedure TMainForm.BenchmarkStartClick(Sender: TObject);
begin
  if (FTask<>nil) or BenchmarkBusy then Exit;
  if not FBenchThreads.CommitInput then Exit;
  FreeAndNil(FBenchBackend);
  try
    FBenchBackend := TLzmaBenchmark.Create(BenchmarkConfig);
    FBenchBackend.Start;
    FBenchLast := FBenchBackend.Snapshot;
    FBenchTimer.Enabled := True;
    SetBenchmarkBusy(True);
    RenderBenchmark;
    SetTaskbarProgress(0,False);
  except
    on E:Exception do
    begin
      FreeAndNil(FBenchBackend);
      SetBenchmarkBusy(False);
      FBenchStateLabel.Caption := E.Message;
      FBenchStateLabel.Font.Color := RGB(255,100,110);
    end;
  end;
end;

procedure TMainForm.BenchmarkStopClick(Sender: TObject);
begin
  if FBenchBackend=nil then Exit;
  FBenchBackend.Cancel;
  FBenchStop.Caption := TextOf('Stopping…');
  SetPanelButtonEnabled(FBenchStop,False,False);
end;

procedure TMainForm.BenchmarkTimer(Sender: TObject);
begin
  if FBenchBackend=nil then Exit;
  FBenchLast := FBenchBackend.Snapshot;
  RenderBenchmark;
  if FBenchLast.Finished then
  begin
    FBenchTimer.Enabled := False;
    FBenchBackend.Wait;
    FreeAndNil(FBenchBackend);
    SetBenchmarkBusy(False);
    BenchmarkSettingsChanged(nil);
    ClearTaskbarProgress;
  end
  else SetTaskbarProgress(FBenchLast.CompletedPasses*100 div Max(1,FBenchLast.Config.Passes),False);
end;

procedure TMainForm.RenderBenchmark;
var Side,Column,Metric: Integer;
    M: TBenchmarkMetric;
    Value: Double;
    Text: string;
begin
  if FBenchmarkPanel=nil then Exit;
  if FBenchCopy.Visible<>(FBenchLast.CompletedPasses>0) then
  begin
    FBenchCopy.Visible:=FBenchLast.CompletedPasses>0;
    LayoutBenchmark;
  end;
  for Side := 0 to 1 do
    for Column := 0 to 1 do
    begin
      if Side=0 then
      begin
        if Column=0 then M:=FBenchLast.CurrentCompression else M:=FBenchLast.AverageCompression;
      end
      else if Column=0 then M:=FBenchLast.CurrentDecompression else M:=FBenchLast.AverageDecompression;
      for Metric := 0 to 3 do
      begin
        case Metric of
          0: Value:=M.SpeedKiB;
          1: Value:=M.UsagePercent;
          2: Value:=M.RatingPerUsage;
        else Value:=M.RatingMips;
        end;
        Text:='–';
        if M.WallSeconds>0 then
          if Metric=1 then Text:=FormatFloat('0.0',Value,GuiNumberFormat(Ord(FLanguage))) else Text:=FormatFloat('#,##0',Value,GuiNumberFormat(Ord(FLanguage)));
        FBenchValues[Side,Column,Metric].Caption:=Text;
      end;
    end;
  FBenchOverall.Caption:='–';
  if FBenchLast.CompletedPasses>0 then
    FBenchOverall.Caption:=FormatFloat('#,##0',(FBenchLast.AverageCompression.RatingMips+
      FBenchLast.AverageDecompression.RatingMips)/2,GuiNumberFormat(Ord(FLanguage)))+' MIPS';
  FBenchStateLabel.Font.Color:=UiText;
  case FBenchLast.State of
    bsIdle: FBenchStateLabel.Caption:='';
    bsPreparing: FBenchStateLabel.Caption:=TextOf('Preparing test data…');
    bsCompressing: FBenchStateLabel.Caption:=TextOf('Benchmarking compression…');
    bsDecompressing: FBenchStateLabel.Caption:=TextOf('Benchmarking extraction…');
    bsComplete: FBenchStateLabel.Caption:=TextOf('Benchmark complete');
    bsCancelled: FBenchStateLabel.Caption:=TextOf('Benchmark stopped');
    bsError:
      begin FBenchStateLabel.Caption:=FBenchLast.ErrorText;FBenchStateLabel.Font.Color:=RGB(255,100,110);end;
  end;
  FBenchStateLabel.Hint:=FBenchStateLabel.Caption;
  FBenchStateLabel.ShowHint:=True;
  FBenchStateLabel.EllipsisPosition:=epEndEllipsis;
  FBenchProgressLabel.Caption:='';
  if FBenchLast.State<>bsIdle then
    FBenchProgressLabel.Caption:=Format(TextOf('Time: %.1f s · passes: %d/%d · workers: %d'),
      [FBenchLast.ElapsedMilliseconds/1000.0,FBenchLast.CompletedPasses,FBenchLast.Config.Passes,FBenchLast.Config.Workers],GuiNumberFormat(Ord(FLanguage)));
end;

procedure TMainForm.BenchmarkCopyClick(Sender: TObject);
var Text: TStringList;
  procedure Metric(const Name: string; const M: TBenchmarkMetric);
  begin
    Text.Add(Format('%s: %.0f KiB/s; CPU %.1f%%; R/U %.0f MIPS; rating %.0f MIPS',
      [Name,M.SpeedKiB,M.UsagePercent,M.RatingPerUsage,M.RatingMips],TFormatSettings.Invariant));
  end;
begin
  if FBenchLast.CompletedPasses<1 then Exit;
  Text:=TStringList.Create;
  try
    Text.Add(GuiProductName+' '+GuiProductVersion+' – LZMA benchmark');
    Text.Add(Format('Dictionary: %d MB; workers: %d; completed passes: %d/%d',
      [FBenchLast.Config.DictionarySize shr 20,FBenchLast.Config.Workers,
       FBenchLast.CompletedPasses,FBenchLast.Config.Passes]));
    Metric('Compression',FBenchLast.AverageCompression);
    Metric('Extraction',FBenchLast.AverageDecompression);
    Text.Add(Format('Total rating: %.0f MIPS',[(FBenchLast.AverageCompression.RatingMips+
      FBenchLast.AverageDecompression.RatingMips)/2],TFormatSettings.Invariant));
    Text.Add(Format('Elapsed: %.1f s; memory limit: %d bytes',
      [FBenchLast.ElapsedMilliseconds/1000.0,FBenchLast.Config.MemoryLimit],TFormatSettings.Invariant));
    Text.Add('Rating formulas: 7-Zip 26.05; independent single-thread LZMA workers.');
    Clipboard.AsText:=Text.Text;
  finally Text.Free;end;
end;
