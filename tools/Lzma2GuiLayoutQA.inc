{$IFDEF GUI_LAYOUT_QA}
procedure TMainForm.RunLayoutAudit(const Destination: string);
const Dpis: array[0..5] of Integer = (96,120,144,168,192,240);
      Widths: array[0..3] of Integer = (640,720,896,1280);
var Dpi, W, Lang, Mode, Custom, Cases, Checks, I, N, PreviousN: Integer;
    BudgetMB, StartupDpi: Integer;
    StartupMetrics: string;
    MenuMetrics: TNonClientMetrics;
    Failures: TStringList;
    Context: string;
    Options: TLzma2Options;
    ThreadProbe:TThreadChoiceCombo;
    Key:Word;

  procedure NotifyThread(const Code:Word);
  begin ThreadProbe.Perform(CN_COMMAND,MakeWParam(0,Code),0);end;

  procedure Check(const Condition: Boolean; const Detail: string);
  begin
    Inc(Checks);
    if not Condition then Failures.Add(Context + ': ' + Detail);
  end;

  procedure Fits(const C: TControl);
  begin
    Check((C.Left >= 0) and (C.Top >= 0) and
      (C.Left + C.Width <= C.Parent.ClientWidth + 1) and
      (C.Top + C.Height <= C.Parent.ClientHeight + 1), C.ClassName + ' exceeds parent');
  end;

  procedure TextFits(const P: TPanel);
  begin
    Canvas.Font.Assign(P.Font);
    Check(Canvas.TextWidth(P.Caption) + ScaleValue(12) <= P.Width,
      'Clipped button: ' + P.Caption);
  end;

  procedure LabelFits(const C: TLabel);
  var Bounds: TRect;
  begin
    Fits(C);
    Canvas.Font.Assign(C.Font);
    if C.WordWrap then
    begin
      Bounds := Rect(0,0,C.Width,0);
      DrawText(Canvas.Handle, PChar(C.Caption), Length(C.Caption), Bounds,
        DT_CALCRECT or DT_WORDBREAK or DT_NOPREFIX);
      Check(Bounds.Height<=C.Height, 'Clipped label: '+C.Caption);
    end
    else
      Check(Canvas.TextWidth(C.Caption)<=C.Width, 'Clipped label: '+C.Caption);
  end;

  procedure FontFits(const AFont:TFont; const TextHeight:Integer; const Detail:string);
  begin
    Check(Abs(Abs(AFont.Height)-ScaleValue(TextHeight))<=1, Detail+
      Format(' (font=%d, expected=%d)',[AFont.Height,ScaleValue(TextHeight)]));
  end;

  procedure LabelGapFits(const C: TLabel; const Field: TControl);
  begin
    Check(Field.Top-C.Top-C.Height=ScaleValue(UiLabelGap),'Label gap differs for '+C.Caption);
  end;

  procedure EditFits(const Edit:TEdit);
  var DC:HDC;PreviousFont:HGDIOBJ;Metrics:TTextMetric;Bottom:Integer;
  begin
    DC:=GetDC(Edit.Handle);
    try
      PreviousFont:=SelectObject(DC,Edit.Font.Handle);
      try
        Check(GetTextMetrics(DC,Metrics),'Cannot read native edit font metrics');
        Check(Edit.ClientHeight>Metrics.tmHeight,'Native edit has no spare space for caret/descenders');
        Check(Edit.ClientHeight=Metrics.tmHeight+2,'Borderless edit retains excess native frame padding');
      finally SelectObject(DC,PreviousFont);end;
    finally ReleaseDC(Edit.Handle,DC);end;
    Bottom:=Edit.Parent.ClientHeight-Edit.Top-Edit.Height;
    Check(Abs(Edit.Top-Bottom)<=1,'Native edit top/bottom padding differs');
    Check(Edit.Top>=Bottom,'Odd native edit padding must not raise the text');
    Check(Min(Edit.Top,Bottom)>=ScaleValue(5),'Native edit padding is too tight');
  end;

begin
  Cases := 0;
  Checks := 0;
  Failures := TStringList.Create;
  try
    AuditGuiEditHints(Self,UiInput,UiText,UiSubtleText,Checks,Failures);
    AuditGuiHints(Checks,Failures);
    Context := 'Auto thread policy';
    Options := TLzma2.DefaultOptions;
    Options.Container := lcXz;
    for W in [1,2,6,32,128] do
      for I in [1,4,64,128] do
      begin
        Options.DictionarySize := UInt64(I) shl 20;
        PreviousN := 1;
        for BudgetMB in [0,128,512,2048,8192] do
        begin
          N := AutoThreadCount(Options,UInt64(BudgetMB) shl 20,W);
          Check((N>=1) and (N<=W),'Auto exceeds CPU ceiling');
          Check(N>=PreviousN,'Auto is not monotonic with available memory');
          PreviousN := N;
        end;
      end;
    Options.Container := lcLzma;
    Check(AutoThreadCount(Options,High(UInt64),128)=2,'Normal standalone LZMA Auto must use both SDK stages');
    Check(AutoThreadCount(Options,High(UInt64),1)=1,'Standalone LZMA Auto exceeds a single available CPU');
    Options.Container := lcXz;
    Options.Level := 0;
    Check(AutoThreadCount(Options,High(UInt64),128)=1,'Copy mode must use one worker');
    Options.Level := 6;
    Options.DictionarySize := High(UInt64);
    Check(AutoThreadCount(Options,High(UInt64),128)=1,'Auto estimate must avoid overflow');
    FThreadsCombo.RequestedWorkers := 6;
    UpdateAutoThreads;
    Check(FThreadsCombo.RequestedWorkers=6,'Updating Auto caption must retain manual selection');
    Check(BuildOptions.ThreadCount=6,'Manual thread count must reach the API');
    Context:='Native thread choice state';
    ThreadProbe:=TThreadChoiceCombo.Create(Self);
    try
      ThreadProbe.Parent:=FSettingsPanel;
      ThreadProbe.Configure(4,'Auto','Other...','Manual: %d');
      ThreadProbe.RequestedWorkers:=999;
      Check((ThreadProbe.Items.Count=6) and (ThreadProbe.ItemIndex=5) and
        (ThreadProbe.RequestedWorkers=999),'Custom request must not add fabricated CPU choices');
      NotifyThread(CBN_DROPDOWN);ThreadProbe.ItemIndex:=2;NotifyThread(CBN_SELCHANGE);
      Check(ThreadProbe.RequestedWorkers=999,'Preview committed before acceptance');
      NotifyThread(CBN_SELENDCANCEL);NotifyThread(CBN_SELCHANGE);NotifyThread(CBN_CLOSEUP);
      Check((ThreadProbe.RequestedWorkers=999) and (ThreadProbe.ItemIndex=5),'Esc changed the previous manual request');
      NotifyThread(CBN_DROPDOWN);ThreadProbe.ItemIndex:=2;NotifyThread(CBN_SELCHANGE);
      NotifyThread(CBN_SELENDOK);NotifyThread(CBN_CLOSEUP);
      Check((ThreadProbe.RequestedWorkers=2) and (ThreadProbe.ItemIndex=2),'Accepted numeric selection did not commit');
      ThreadProbe.RequestedWorkers:=129;ThreadProbe.Configure(256,'Auto','Other...','Manual: %d');
      Check((ThreadProbe.RequestedWorkers=129) and (ThreadProbe.ItemIndex=129) and
        (ThreadProbe.Items.Count=258),'Available CPU count is capped or changes the saved request');
      ThreadProbe.Configure(4,'Auto','Other...','Manual: %d');
      Check((ThreadProbe.RequestedWorkers=129) and (ThreadProbe.ItemIndex=5),'CPU inventory change lost the manual request');
      ThreadProbe.Text:='2147483647';NotifyThread(CBN_EDITCHANGE);
      Check(ThreadProbe.InputValid and (ThreadProbe.RequestedWorkers=129),
        'Inline input committed before acceptance or rejects a valid Int32 request');
      ThreadProbe.UpdateCaptions('Auto (up to 4)','Other...','Manual: %d');
      Check(ThreadProbe.Text='2147483647','Caption refresh overwrote pending inline input');
      Check(ThreadProbe.CommitInput and (ThreadProbe.RequestedWorkers=High(Integer)),
        'Inline input silently caps a positive request');
      ThreadProbe.Text:='2147483648';NotifyThread(CBN_EDITCHANGE);
      Check(not ThreadProbe.InputValid and not ThreadProbe.CommitInput and
        (ThreadProbe.RequestedWorkers=High(Integer)),'Overflow input changed the committed request');
      ThreadProbe.Text:='0';NotifyThread(CBN_EDITCHANGE);
      Check(not ThreadProbe.InputValid and not ThreadProbe.CommitInput,'Zero is not a positive manual request');
      ThreadProbe.Text:='-1';NotifyThread(CBN_EDITCHANGE);
      Check(not ThreadProbe.InputValid,'Negative inline input is valid');
      ThreadProbe.Text:='';NotifyThread(CBN_EDITCHANGE);
      Check(not ThreadProbe.InputValid,'Empty inline input is valid');
      ThreadProbe.Text:='abc';NotifyThread(CBN_EDITCHANGE);
      Check(not ThreadProbe.InputValid,'Nonnumeric inline input is valid');
      Key:=VK_ESCAPE;ThreadProbe.KeyDown(Key,[]);
      Check(ThreadProbe.InputValid and (ThreadProbe.RequestedWorkers=High(Integer)) and
        (ThreadProbe.Text=IntToStr(High(Integer))),'Esc did not restore the committed inline request');
    finally ThreadProbe.Free;end;
    Context:='Auto captions across all locales';
    FThreadsCombo.RequestedWorkers:=0;
    for Lang:=Ord(Low(TGuiLanguage)) to Ord(High(TGuiLanguage)) do
    begin
      // Native/accessibility text refresh without an edit must remain Auto.
      FThreadsCombo.Text:=FThreadsCombo.Text;
      ApplyLanguage(Lang);
      Check((FThreadsCombo.RequestedWorkers=0) and FThreadsCombo.InputValid,
        'Locale switch invalidated the automatic thread request');
      Check(Pos(TextOf('Auto'),FThreadsCombo.Text)=1,
        'Automatic thread caption stayed in the previous language');
    end;
    Context:='Large manual benchmark admission';
    FBenchThreads.RequestedWorkers:=High(Integer);
    FBenchDictionary.ItemIndex:=High(BenchmarkDictionaryMb);
    BenchmarkSettingsChanged(nil);
    Check(not FBenchStart.Enabled,'Unadmittable manual benchmark request remains runnable');
    Check(FBenchThreads.RequestedWorkers=High(Integer),'Admission rewrote an explicit manual request');
    FBenchThreads.RequestedWorkers:=0;FBenchDictionary.ItemIndex:=0;BenchmarkSettingsChanged(nil);
    Check(FLanguageButton.TabOrder<FAboutButton.TabOrder,'Header keyboard order differs from visual order');
    ApplyLanguage(1);
    FBenchLast:=Default(TBenchmarkSnapshot);
    FBenchLast.State:=bsComplete;FBenchLast.CompletedPasses:=1;
    FBenchLast.AverageCompression.WallSeconds:=1;
    FBenchLast.AverageCompression.Commands:=3463.0*1000000;
    FBenchLast.AverageDecompression.WallSeconds:=1;
    FBenchLast.AverageDecompression.Commands:=9599.0*1000000;
    FBenchLast.ElapsedMilliseconds:=61500;
    RenderBenchmark;
    Check(FBenchOverall.Caption='6'+#160+'531 MIPS','Overall benchmark rating ignores the selected UI locale');
    Check(Pos('61,5',FBenchProgressLabel.Caption)>0,'Benchmark elapsed time ignores the selected UI locale');
    FBenchLast:=Default(TBenchmarkSnapshot);
    StartupDpi := GetDpiForWindow(Handle);
    Context := Format('Cold startup %d DPI',[StartupDpi]);
    MenuMetrics := Default(TNonClientMetrics);
    MenuMetrics.cbSize := SizeOf(MenuMetrics);
    Check(SystemParametersInfoForDpi(SPI_GETNONCLIENTMETRICS,MenuMetrics.cbSize,@MenuMetrics,0,StartupDpi),
      'Windows system menu metrics unavailable');
    StartupMetrics := Format('width=%d height=%d pathFont=%d browseFont=%d comboFont=%d labelFont=%d '+
      'benchHeadingFont=%d titleFont=%d languageFont=%d aboutFont=%d systemMenuFont="%s %d"',
      [ClientWidth,ClientHeight,Abs(FInputEdit.Font.Height),Abs(FInputBrowseButton.Font.Height),
       Abs(FThreadsCombo.Font.Height),Abs(FContainerLabel.Font.Height),Abs(FBenchMetricLabels[0,0].Font.Height),
       Abs(FTitleLabel.Font.Height),Abs(FLanguageButton.Font.Height),Abs(FAboutButton.Font.Height),
       PChar(@MenuMetrics.lfMenuFont.lfFaceName[0]),Abs(MenuMetrics.lfMenuFont.lfHeight)]);
    Check(StartupDpi=CurrentPPI,'VCL startup scale differs from the native window');
    FontFits(FInputEdit.Font,UiBodyText,'Path edit startup font');
    FontFits(FInputBrowseButton.Font,UiBodyText,'Browse startup font');
    FontFits(FThreadsCombo.Font,UiBodyText,'Thread picker startup font');
    FontFits(FContainerLabel.Font,UiBodyText,'Settings label startup font');
    FontFits(FBenchMetricLabels[0,0].Font,UiSmallText,'Benchmark heading startup font');
    FontFits(FTitleLabel.Font,UiTitleText,'Window title startup font');
    FontFits(FLanguageButton.Font,UiBodyText,'Language action startup font');
    FontFits(FAboutButton.Font,UiBodyText,'About action startup font');
    Constraints.MinWidth := 0;
    Constraints.MinHeight := 0;
    for Dpi in Dpis do
    begin
      ScaleForPPI(Dpi);
      for W in Widths do
      begin
        ClientWidth := MulDiv(W, Dpi, 96);
        if W=Widths[Low(Widths)] then
          ClientHeight := MulDiv(UiMinimumHeight, Dpi, 96)
        else
          ClientHeight := MulDiv(UiDefaultHeight, Dpi, 96);
        for Lang := Ord(Low(TGuiLanguage)) to Ord(High(TGuiLanguage)) do
        begin
          ApplyLanguage(Lang);
          for Mode := 0 to 2 do
            for Custom := 0 to 2 do
            begin
              FModeIndex := Mode;
              if Custom=0 then FDictionaryIndex:=0
              else if Custom=1 then FDictionaryIndex:=Length(DictionaryMbValues)
              else FDictionaryIndex:=Length(DictionaryMbValues)+1;
              if Custom=0 then FContainerIndex:=3 else FContainerIndex:=2;
              FThreadsCombo.RequestedWorkers := 0;
              UpdateModeButtons;
              UpdateOptionButtons;
              LayoutMainPanels;
              Context := Format('%d DPI, %d px, %s, mode=%d, custom=%d',
                [Dpi,W,GuiLanguageCodes[FLanguage],Mode,Custom]);
              Inc(Cases);
              LabelFits(FTitleLabel);Fits(FLanguageButton);Fits(FAboutButton);TextFits(FAboutButton);
              Check(FTitleLabel.Left+FTitleLabel.Width<=FLanguageButton.Left,'Window title overlaps language action');
              Check(CaptionWidth(FLanguageButton.Caption,FLanguageButton.Font)+ScaleValue(40)<=FLanguageButton.Width,
                'Language action lacks space for its caption and glyph');
              Check(FLanguageButton.Left+FLanguageButton.Width<=FAboutButton.Left,'Language must precede About in the header');
              Check(FAboutButton.Left+FAboutButton.Width<=FWindowButtons[wbMinimize].Left,'About overlaps window buttons');
              Check((FLanguageButton.Top=FAboutButton.Top) and (FLanguageButton.Height=FAboutButton.Height),'Header actions differ in height or baseline');
              FontFits(FTitleLabel.Font,UiTitleText,'Window title DPI font');
              FontFits(FLanguageButton.Font,UiBodyText,'Language action DPI font');
              FontFits(FAboutButton.Font,UiBodyText,'About action DPI font');
              Fits(FResizeGrip);
              Check(FResizeGrip.Height=ScaleValue(UiResizeGripSize),'Resize grip height drifts');
              Check(FResizeGrip.Top+FResizeGrip.Height=ClientHeight,'Resize grip is detached from the bottom edge');
              FontFits(FInputBrowseButton.Font,UiBodyText,'Browse DPI font');
              FontFits(FContainerLabel.Font,UiBodyText,'Settings label DPI font');
              FontFits(FInputEdit.Font,UiBodyText,'Path edit DPI font');
              FontFits(FThreadsCombo.Font,UiBodyText,'Thread selector DPI font');
              Fits(FModePanel);
              TextFits(FCompressModeButton);TextFits(FDecompressModeButton);TextFits(FBenchmarkModeButton);
              Check(FCheckGroup.Visible=((Mode=0) and (FContainerIndex=2)),'Checksum controls are visible outside XZ compression');
              Check(FLevelCombo.Visible=(Mode=0),'Compression level remains visible outside compression');
              Check(FDictionaryCombo.Visible=(Mode=0),'Compression dictionary remains visible outside compression');
              if Mode=2 then
              begin
                Fits(FBenchmarkPanel);Fits(FBenchDictionary);Fits(FBenchThreads);Fits(FBenchPasses);
                Fits(FBenchStart);Fits(FBenchStateLabel);Fits(FBenchProgressLabel);
                TextFits(FBenchStart);
                Check(FBenchStart.Top+FBenchStart.Height+ScaleValue(UiActionInset)=FBenchmarkPanel.ClientHeight,
                  'Benchmark action bottom spacing differs');
                if FBenchCopy.Visible then
                begin
                  Fits(FBenchCopy);TextFits(FBenchCopy);
                  Check(FBenchCopy.Left+FBenchCopy.Width<=FBenchStart.Left,'Benchmark actions overlap');
                  Check((FBenchCopy.Height=FBenchStart.Height) and
                    (FBenchCopy.Top=FBenchStart.Top),'Benchmark action heights or baselines differ');
                end;
                Check(FBenchStateLabel.Top=FBenchStart.Top,'Benchmark footer text and actions drift');
                Check(FBenchProgressLabel.Top+FBenchProgressLabel.Height<=FBenchStart.Top+FBenchStart.Height,
                  'Benchmark footer text extends below the actions');
                for I:=0 to 2 do LabelFits(FBenchSettingLabels[I]);
                LabelGapFits(FBenchSettingLabels[0],FBenchDictionary);
                LabelGapFits(FBenchSettingLabels[1],FBenchThreads);
                LabelGapFits(FBenchSettingLabels[2],FBenchPasses);
                for I:=0 to 3 do
                begin
                  LabelFits(FBenchMetricLabels[0,I]);
                  Check(FBenchValues[0,0,I].Left=FBenchValues[1,1,I].Left,'Benchmark numeric columns drift');
                  Check(FBenchValues[0,0,I].Width=FBenchMetricLabels[0,I].Width,'Benchmark header/value columns differ');
                end;
                for I:=0 to 1 do
                begin
                  LabelFits(FBenchHeadings[I]);
                  LabelFits(FBenchColumns[I,0]);LabelFits(FBenchColumns[I,1]);
                end;
              end
              else
              begin
                Fits(FInputRow);Fits(FOutputRow);Fits(FSettingsPanel);Fits(FActivityPanel);
                Fits(FInputShell);Fits(FOutputShell);EditFits(FInputEdit);EditFits(FOutputEdit);
                LabelFits(FInputLabel);LabelFits(FOutputLabel);
                LabelGapFits(FInputLabel,FInputShell);LabelGapFits(FOutputLabel,FOutputShell);
                Fits(FInputBrowseButton);Fits(FOutputBrowseButton);
                TextFits(FInputBrowseButton);TextFits(FOutputBrowseButton);TextFits(FStartButton);
                Fits(FContainerGroup);Fits(FThreadsCombo);Fits(FStartButton);
                LabelFits(FContainerLabel);LabelFits(FThreadsLabel);
                LabelGapFits(FContainerLabel,FContainerGroup);LabelGapFits(FThreadsLabel,FThreadsCombo);
                Check(FActivityPanel.Top>=FSettingsPanel.Top+FSettingsPanel.Height+ScaleValue(UiGap),
                  'Activity band is too close to codec settings');
                Check(FStartButton.Top+FStartButton.Height+ScaleValue(UiActionInset)=FActivityPanel.ClientHeight,
                  'File action bottom spacing differs');
                for I:=0 to 3 do TextFits(FContainerButtons[I]);
                Check(FInputBrowseButton.Left=FOutputBrowseButton.Left,'Browse buttons not aligned');
                Check((FInputShell.Height=FInputBrowseButton.Height) and
                  (FOutputShell.Height=FOutputBrowseButton.Height),'Field and browse heights differ');
                Check(FInputRow.Top>=FModePanel.Top+FModePanel.Height+ScaleValue(12),'Mode/path gap too small');
                Check(FOutputRow.Top=FInputRow.Top+FInputRow.Height+ScaleValue(12),'Path row spacing differs');
                Check(FSettingsPanel.Top=FOutputRow.Top+FOutputRow.Height+ScaleValue(20),'File and settings groups lack separation');
                Check(FSettingsPanel.Top+FSettingsPanel.Height<=FActivityPanel.Top,'Action overlaps settings');
                if Mode=0 then
                begin
                  Fits(FLevelCombo);Fits(FDictionaryCombo);
                  LabelFits(FLevelLabel);LabelFits(FDictionaryLabel);
                  LabelGapFits(FLevelLabel,FLevelCombo);LabelGapFits(FDictionaryLabel,FDictionaryCombo);
                  Check((FLevelCombo.Top=FDictionaryCombo.Top) and (FThreadsCombo.Top=FLevelCombo.Top),'Settings baselines differ');
                  Check(FDictionaryCombo.Left>=FLevelCombo.Left+FLevelCombo.Width+ScaleValue(12),'Settings overlap');
                  Check(FThreadsCombo.Left>=FDictionaryCombo.Left+FDictionaryCombo.Width+ScaleValue(12),'Threads overlap');
                  if FCheckGroup.Visible then
                  begin
                    Fits(FCheckGroup);LabelFits(FCheckLabel);
                    LabelGapFits(FCheckLabel,FCheckGroup);
                    for I:=0 to 3 do TextFits(FCheckButtons[I]);
                  end;
                  if Custom=1 then
                  begin
                    Fits(FDictionaryCustomShell);EditFits(FDictionaryCustomEdit);
                    Check(FDictionaryCustomShell.Left=FDictionaryCombo.Left,'Custom dictionary is outside its column');
                    Check(FDictionaryCustomShell.Top>=FDictionaryCombo.Top+FDictionaryCombo.Height+ScaleValue(4),'Custom dictionary overlaps its selector');
                  end;
                end
                else
                  Check(FThreadsCombo.Top=FContainerGroup.Top,'Extraction settings baselines differ');
                Check((FThreadsCombo.RequestedWorkers=0) and FThreadsCombo.InputValid and
                  (Pos(TextOf('Auto'),FThreadsCombo.Text)=1),'Localized Auto selection disappeared or became invalid');
                if Custom<>1 then
                begin
                  Options:=BuildOptions;
                  Check((Options.ThreadCount>=1) and (Options.MemoryLimit>0),'Auto resource admission');
                end;
              end;
            end;
        end;
      end;
    end;
    FModeIndex:=0;
    FContainerIndex:=3;
    UpdateModeButtons;
    UpdateOptionButtons;
    FInputEdit.Text := 'E:\Рабочие материалы\Длинное название проекта ' + StringOfChar(WideChar($044F),160) + '\исходные данные.bin';
    FOutputEdit.Text := 'E:\Архивы\Длинное имя результата ' + StringOfChar(WideChar('x'),180) + '.xz';
    UpdateStartState;
    Check(FReadyLabel.Visible, 'Long-path ready state missing');
    FInputEdit.Clear; FOutputEdit.Clear;
    UpdateStartState;
    Check(not FReadyLabel.Visible, 'Duplicate empty-state hint');
    Failures.Insert(0,Format('cases=%d checks=%d failures=%d startupDpi=%d %s',[Cases,Checks,Failures.Count,StartupDpi,StartupMetrics]));
    Failures.SaveToFile(Destination,TEncoding.UTF8);
    if Failures.Count > 1 then raise Exception.Create('GUI layout audit failed; see '+Destination);
  finally
    Failures.Free;
  end;
end;
{$ENDIF}
