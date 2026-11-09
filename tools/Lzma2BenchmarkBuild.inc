  procedure BuildBenchmarkControls;
  var Side, Column, Metric, J: Integer;
      DefaultCheck: TBenchmarkConfig;
  begin
    FBenchmarkPanel := MakeSurface(FFilesPanel);
    FBenchmarkPanel.Visible := False;
    for J := 0 to 2 do FBenchSettingLabels[J] := AddText(FBenchmarkPanel,'',UiBodyText,True);
    FBenchDictionary := TOptionCombo.Create(Self);
    FBenchDictionary.Parent := FBenchmarkPanel;
    for J := 0 to High(BenchmarkDictionaryMb) do
      FBenchDictionary.Items.Add(DictionaryCaption(BenchmarkDictionaryMb[J]));
    // 7-Zip 26.05 starts at 32 MiB; reduce only if one worker cannot fit.
    FBenchDictionary.ItemIndex := 0;
    for J:=0 to High(BenchmarkDictionaryMb) do
      if BenchmarkDictionaryMb[J]=GuiBenchmarkDefault('dictionaryMiB') then FBenchDictionary.ItemIndex:=J;
    DefaultCheck := Default(TBenchmarkConfig);
    DefaultCheck.Workers := 1;
    DefaultCheck.MemoryLimit := GuiMemoryBudget;
    repeat
      DefaultCheck.DictionarySize := UInt64(BenchmarkDictionaryMb[FBenchDictionary.ItemIndex]) shl 20;
      if (TLzmaBenchmark.RequiredMemory(DefaultCheck)<=DefaultCheck.MemoryLimit) or
        (FBenchDictionary.ItemIndex=0) then Break;
      FBenchDictionary.ItemIndex := FBenchDictionary.ItemIndex-1;
    until False;
    FBenchDictionary.OnChange := BenchmarkSettingsChanged;
    FBenchThreads := TThreadChoiceCombo.Create(Self);
    FBenchThreads.Parent := FBenchmarkPanel;
    FBenchThreads.Configure(GuiProcessorCount,TextOf('Auto'),TextOf('Other...'),TextOf('Manual: %d'));
    FBenchThreads.RequestedWorkers := GuiBenchmarkDefault('threads');
    FBenchThreads.OnChange := BenchmarkSettingsChanged;
    FBenchPasses := TOptionCombo.Create(Self);
    FBenchPasses.Parent := FBenchmarkPanel;
    for J := 0 to High(BenchmarkPassCounts) do FBenchPasses.Items.Add(IntToStr(BenchmarkPassCounts[J]));
    FBenchPasses.ItemIndex := 0;
    for J:=0 to High(BenchmarkPassCounts) do
      if BenchmarkPassCounts[J]=GuiBenchmarkDefault('passes') then FBenchPasses.ItemIndex:=J;
    FBenchPasses.OnChange := BenchmarkSettingsChanged;
    FBenchSettingLabels[0].FocusControl := FBenchDictionary;
    FBenchSettingLabels[1].FocusControl := FBenchThreads;
    FBenchSettingLabels[2].FocusControl := FBenchPasses;
    FBenchMemory := AddText(FBenchmarkPanel,'',UiSmallText,True);
    FBenchMemory.ShowHint := True;
    for Side := 0 to 1 do
    begin
      FBenchHeadings[Side] := AddText(FBenchmarkPanel,'',UiBodyText,False,True);
      for Column := 0 to 1 do
      begin
        FBenchColumns[Side,Column] := AddText(FBenchmarkPanel,'',UiSmallText,True);
        FBenchColumns[Side,Column].Alignment := taRightJustify;
        for Metric := 0 to 3 do
        begin
          FBenchValues[Side,Column,Metric] := AddText(FBenchmarkPanel,'',UiBodyText);
          FBenchValues[Side,Column,Metric].Alignment := taRightJustify;
          FBenchValues[Side,Column,Metric].Layout := tlCenter;
        end;
      end;
      for Metric := 0 to 3 do
      begin
        FBenchMetricLabels[Side,Metric] := AddText(FBenchmarkPanel,'',UiSmallText,True);
        FBenchMetricLabels[Side,Metric].Layout := tlCenter;
      end;
    end;
    FBenchTableHeader := AddText(FBenchmarkPanel,'',UiSmallText,True);
    FBenchOverallTitle := AddText(FBenchmarkPanel,'',UiBodyText,False,True);
    FBenchOverall := AddText(FBenchmarkPanel,'',UiTitleText,False,True);
    FBenchOverall.Alignment := taRightJustify;
    FBenchOverall.Font.Color := UiAccentHover;
    FBenchStateLabel := AddText(FBenchmarkPanel,'',UiBodyText,False,True);
    FBenchProgressLabel := AddText(FBenchmarkPanel,'',UiSmallText,True);
    FBenchStart := MakeButton(FBenchmarkPanel,'',True,BenchmarkStartClick);
    FBenchStop := MakeButton(FBenchmarkPanel,'',False,BenchmarkStopClick);
    FBenchStop.Visible := False;
    FBenchCopy := MakeButton(FBenchmarkPanel,'',False,BenchmarkCopyClick);
    FBenchCopy.Visible := False;
    SetPanelButtonEnabled(FBenchCopy,False,False);
    FBenchTimer := TTimer.Create(Self);
    FBenchTimer.Interval := 100;
    FBenchTimer.Enabled := False;
    FBenchTimer.OnTimer := BenchmarkTimer;
  end;
