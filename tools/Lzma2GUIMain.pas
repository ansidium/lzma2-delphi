unit Lzma2GUIMain;

interface

uses
  System.Classes,
  System.Diagnostics,
  System.Generics.Collections,
  System.IOUtils,
  System.IniFiles,
  System.Math,
  System.SyncObjs,
  System.SysUtils,
  System.Threading,
  System.Types,
  System.UITypes,
  Winapi.ActiveX,
  Winapi.Dwmapi,
  Winapi.D2D1,
  Winapi.Messages,
  Winapi.MultiMon,
  Winapi.ShlObj,
  Winapi.ShellAPI,
  Winapi.UxTheme,
  Winapi.Windows,
  Vcl.ComCtrls,
  Vcl.Controls,
  Vcl.Dialogs,
  Vcl.Direct2D,
  Vcl.ExtCtrls,
  Vcl.Forms,
  Vcl.GraphUtil,
  Vcl.Graphics,
  Vcl.Menus,
  Vcl.StdCtrls,
  Lzma.Api,
  Lzma.Errors,
  Lzma.SevenZip,
  Lzma.Types,
  Lzma2ThreadChoice,
  Lzma2GuiScrollbars,
  Lzma2Benchmark;

function GuiProductName: string;
function GuiProductVersion: string;
function GuiSdkTarget: string;
function GuiProjectUrl: string;

type
  TGuiLanguage = (glEnglish, glRussian, glFrench, glFinnish, glItalian,
    glGerman, glSpanish, glCzech, glBrazilian, glPolish, glKorean,
    glChineseSimplified, glJapanese, glTurkish, glDanish, glDutch,
    glHungarian, glNorwegian, glPortuguese, glSwedish, glRomanian,
    glBulgarian, glGreek, glUkrainian);
  TWindowButtonKind = (wbMinimize, wbMaximize, wbClose);
  TPanelGlyphKind = (pgNone, pgFile, pgFolder, pgLanguage);
  TTrackPopupMenuResult = function(hMenu: HMENU; uFlags: UINT; x, y,
    nReserved: Integer; hWnd: HWND; prcRect: PRect): UINT; stdcall;

  TRoundedPanel = class(TPanel)
  private
    FBorderColor: TColor;
    FBorderWidth: Single;
    FCaptionOffsetY: Single;
    FCornerRadius: Integer;
    FGradientToColor: TColor;
    FGlyphKind: TPanelGlyphKind;
    FHasFocus: Boolean;
    FShowKeyboardFocus: Boolean;
    FHover: Boolean;
    FHoverColor: TColor;
    FKeyPressed: Boolean;
    FMousePressed: Boolean;
    FUseGradient: Boolean;
    procedure CMDialogKey(var Message: TCMDialogKey); message CM_DIALOGKEY;
    procedure CMMouseEnter(var Message: TMessage); message CM_MOUSEENTER;
    procedure CMMouseLeave(var Message: TMessage); message CM_MOUSELEAVE;
    procedure WMCaptureChanged(var Message: TMessage); message WM_CAPTURECHANGED;
    procedure UpdateRegion;
  protected
    procedure CreateParams(var Params: TCreateParams); override;
    procedure CreateWnd; override;
    procedure DoEnter; override;
    procedure DoExit; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure KeyUp(var Key: Word; Shift: TShiftState); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure Paint; override;
    procedure Resize; override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure FocusWithCue(const Keyboard: Boolean);
    property BorderColor: TColor read FBorderColor write FBorderColor;
    property BorderWidth: Single read FBorderWidth write FBorderWidth;
    property CaptionOffsetY: Single read FCaptionOffsetY write FCaptionOffsetY;
    property CornerRadius: Integer read FCornerRadius write FCornerRadius;
    property GradientToColor: TColor read FGradientToColor write FGradientToColor;
    property GlyphKind: TPanelGlyphKind read FGlyphKind write FGlyphKind;
    property HoverColor: TColor read FHoverColor write FHoverColor;
    property UseGradient: Boolean read FUseGradient write FUseGradient;
  end;

  TWindowButton = class(TCustomControl)
  private
    FCornerRadius: Integer;
    FHover: Boolean;
    FKind: TWindowButtonKind;
    procedure CMMouseEnter(var Message: TMessage); message CM_MOUSEENTER;
    procedure CMMouseLeave(var Message: TMessage); message CM_MOUSELEAVE;
  protected
    procedure Paint; override;
    procedure CreateWnd; override;
    procedure Resize; override;
  public
    constructor Create(AOwner: TComponent); override;
    property Kind: TWindowButtonKind read FKind write FKind;
    property CornerRadius: Integer read FCornerRadius write FCornerRadius;
  end;

  TOptionCombo = class(TComboBox)
  private
    FHover: Boolean;
    FArrowHover,FArrowPressed: Boolean;
    FControlBuffer: TBitmap;
    FListPresenter: TNativeListPresenter;
    procedure CMMouseEnter(var Message: TMessage); message CM_MOUSEENTER;
    procedure CMMouseLeave(var Message: TMessage); message CM_MOUSELEAVE;
    procedure PaintControl(const DC: HDC);
    procedure UpdateSelectionFieldHeight;
    function ArrowBounds: TRect;
    procedure PaintListItem(const Canvas: TCanvas; const Index: Integer;
      const Bounds: TRect; const Selected: Boolean);
    procedure WMPaint(var Message: TWMPaint); message WM_PAINT;
    procedure WMPrintClient(var Message: TWMPrintClient); message WM_PRINTCLIENT;
  protected
    procedure ChangeScale(M, D: Integer; isDpiChange: Boolean); override;
    procedure CreateWnd; override;
    procedure DestroyWnd; override;
    procedure DrawItem(Index: Integer; Rect: TRect; State: TOwnerDrawState); override;
    function InputInvalid: Boolean; virtual;
    procedure WndProc(var Message: TMessage); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

  TThreadChoiceCombo = class(TOptionCombo)
  private
    FState: TThreadChoiceState;
    FInPopup,FRequestPending,FPopupCancelled: Boolean;
    FEditing,FUpdating,FNotifying,FPopupEditing: Boolean;
    FConfigured:Boolean;
    FTextUpdateDepth:Integer;
    FChangeSerial:UInt64;
    FPopupSelection: Integer;
    FOtherCaption,FAutoCaption,FPopupText: string;
    function GetRequestedWorkers: Integer;
    function CommittedText: string;
    function GetInputValid: Boolean;
    function TryInput(out Value: Integer): Boolean;
    procedure SetRequestedWorkers(const Value: Integer);
    procedure RestoreSelection;
    procedure CommitSelection(const Index: Integer);
    procedure NotifyCommit;
    procedure LayoutEdit;
  protected
    procedure Change; override;
    procedure ChangeScale(M, D: Integer; isDpiChange: Boolean); override;
    procedure ComboWndProc(var Message:TMessage;ComboWnd:HWND;ComboProc:TWindowProcPtr); override;
    procedure CreateParams(var Params: TCreateParams); override;
    procedure CreateWnd; override;
    procedure DoExit; override;
    function InputInvalid: Boolean; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure KeyPress(var Key: Char); override;
    procedure Select; override;
    procedure DestroyWnd; override;
    procedure WndProc(var Message: TMessage); override;
  public
    constructor Create(AOwner: TComponent); override;
    function CommitInput(const NotifyChange: Boolean=True): Boolean;
    procedure Configure(const ProcessorCount: Integer; const AutoCaption,
      OtherCaption,ManualFormat: string);
    procedure UpdateCaptions(const AutoCaption,OtherCaption,ManualFormat: string);
    property RequestedWorkers: Integer read GetRequestedWorkers write SetRequestedWorkers;
    property InputValid: Boolean read GetInputValid;
  end;

  TApplicationMark = class(TGraphicControl)
  private
    FResourceIcon: HICON;
    FIconWidth, FIconHeight: Integer;
  protected
    procedure Paint; override;
  public
    destructor Destroy; override;
  end;

  TGuiResizeGrip = class(TGraphicControl)
  protected
    procedure Paint; override;
  end;

  TGuiFontMetric = record
    Font: TFont;
    LogicalHeight: Integer;
  end;

  TMainForm = class(TForm)
  private
    FInputEdit: TEdit;
    FOutputEdit: TEdit;
    FLanguage: TGuiLanguage;
    FPreferredLanguage: Integer;
    FLanguageButton: TPanel;
    FLanguagePopup: TCustomControl;
    FTitleIcon: TApplicationMark;
    FTitleLabel: TLabel;
    FResizeGrip: TGuiResizeGrip;
    FSmallWindowIcon: TIcon;
    FAboutButton: TPanel;
    FWindowButtons: array[TWindowButtonKind] of TWindowButton;
    FInputLabel: TLabel;
    FOutputLabel: TLabel;
    FModeIndex: Integer;
    FFileModeIndex: Integer;
    FModePanel: TPanel;
    FCompressModeButton: TPanel;
    FDecompressModeButton: TPanel;
    FBenchmarkModeButton: TPanel;
    FBenchmarkPanel: TPanel;
    FBenchDictionary, FBenchPasses: TOptionCombo;
    FBenchThreads: TThreadChoiceCombo;
    FBenchSettingLabels: array[0..2] of TLabel;
    FBenchHeadings: array[0..1] of TLabel;
    FBenchColumns: array[0..1,0..1] of TLabel;
    FBenchMetricLabels: array[0..1,0..3] of TLabel;
    FBenchValues: array[0..1,0..1,0..3] of TLabel;
    FBenchMemory, FBenchTableHeader, FBenchOverallTitle, FBenchOverall: TLabel;
    FBenchStateLabel, FBenchProgressLabel: TLabel;
    FBenchStart, FBenchStop, FBenchCopy: TPanel;
    FBenchTimer: TTimer;
    FBenchBackend: TLzmaBenchmark;
    FBenchLast: TBenchmarkSnapshot;
    FContainerIndex: Integer;
    FLevelIndex: Integer;
    FCheckIndex: Integer;
    FDictionaryIndex: Integer;
    FContainerGroup: TPanel;
    FCheckGroup: TPanel;
    FContainerButtons: array[0..3] of TPanel;
    FLevelCombo: TOptionCombo;
    FCheckButtons: array[0..3] of TPanel;
    FDictionaryCombo: TOptionCombo;
    FDictionaryCustomShell: TPanel;
    FDictionaryCustomEdit: TEdit;
    FThreadsCombo: TThreadChoiceCombo;
    FSettingsPanel: TPanel;
    FContainerLabel: TLabel;
    FLevelLabel: TLabel;
    FCheckLabel: TLabel;
    FDictionaryLabel: TLabel;
    FThreadsLabel: TLabel;
    FMainPanel: TPanel;
    FLayoutActive: Boolean;
    FLogicalFonts: TArray<TGuiFontMetric>;
    FFilesPanel: TPanel;
    FInputRow: TPanel;
    FOutputRow: TPanel;
    FInputShell: TPanel;
    FOutputShell: TPanel;
    FActivityPanel: TPanel;
    FInputBrowseButton: TPanel;
    FOutputBrowseButton: TPanel;
    FStartButton: TPanel;
    FCancelButton: TPanel;
    FProgressTrack: TPanel;
    FProgressFill: TPanel;
    FProgressLabel: TLabel;
    FProgressPercent: Integer;
    FProgressError: Boolean;
    FStatusLabel: TLabel;
    FStatsLabel: TLabel;
    FReadyLabel: TLabel;
    FPollTimer: TTimer;
    FTask: System.Threading.ITask;
    FInputStream: TFileStream;
    FOutputStream: TFileStream;
    FTempOutputPath: string;
    FEncodeDiagnostics: TLzma2EncodeDiagnostics;
    FDecodeDiagnostics: TLzma2DecodeDiagnostics;
    FInputSize: UInt64;
    FLastIn: UInt64;
    FLastOut: UInt64;
    FLastInputDirectory: string;
    FLastOutputDirectory: string;
    FOutputAutoGenerated: Boolean;
    FSourceDialogSelectedPath: string;
    FUpdatingOutputPath: Boolean;
    FCancelRequested: Integer;
    FWatch: TStopwatch;
    FTaskbarList: ITaskbarList3;
    FTaskbarButtonCreatedMessage: UINT;
    FOleInitialized: Boolean;
    procedure BuildUi;
    function BenchmarkBusy: Boolean;
    function BenchmarkConfig: TBenchmarkConfig;
    procedure LayoutBenchmark;
    procedure ApplyBenchmarkLanguage;
    procedure BenchmarkSettingsChanged(Sender: TObject);
    procedure BenchmarkStartClick(Sender: TObject);
    procedure BenchmarkStopClick(Sender: TObject);
    procedure BenchmarkCopyClick(Sender: TObject);
    procedure BenchmarkTimer(Sender: TObject);
    procedure RenderBenchmark;
    procedure SetBenchmarkBusy(const Busy: Boolean);
    procedure ApplyLanguage(const PreferredLanguage: Integer);
    procedure LanguageButtonClick(Sender: TObject);
    procedure LoadLanguagePreference;
    procedure SaveLanguagePreference;
    procedure SavePackingPreference;
    function ResolvedDictionary(const Budget: UInt64): UInt64;
    function BuildOptions: TLzma2Options;
    procedure CollectSevenZipSourceEntries(const SourcePath: string;
      out Entries: TArray<TLzma7zEncodeEntry>; out SourcePaths: TArray<string>;
      out TotalInputBytes: UInt64);
    function DictionaryCaption(const ValueMb: Integer): string;
    function TextOf(const Key: string): string;
    procedure BrowseInputClick(Sender: TObject);
    procedure BrowseOutputClick(Sender: TObject);
    procedure CheckClick(Sender: TObject);
    procedure CloseWindowClick(Sender: TObject);
    procedure ContainerClick(Sender: TObject);
    procedure DictionaryCustomEditChange(Sender: TObject);
    procedure DictionaryChange(Sender: TObject);
    procedure EditChange(Sender: TObject);
    procedure EditEnter(Sender: TObject);
    procedure EditExit(Sender: TObject);
    procedure LevelChange(Sender: TObject);
    function CaptionWidth(const Text: string; const TextFont: TFont): Integer;
    procedure LayoutMainPanels;
    procedure LayoutTitleBar(Sender: TObject);
    procedure ConstrainToWorkArea;
    procedure MainPanelResize(Sender: TObject);
    procedure MaximizeWindowClick(Sender: TObject);
    procedure MinimizeWindowClick(Sender: TObject);
    procedure ModalOkClick(Sender: TObject);
    procedure AboutClick(Sender: TObject);
    procedure OpenProjectPage(Sender: TObject);
    procedure ModalKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    function NewModalDialog(const Caption:string;const W,H:Integer):TForm;
    procedure PrepareModalDialog(const Dialog:TForm;const Corner:TWindowButton;const W,H:Integer);
    procedure PaintModalSurface(Sender: TObject);
    procedure ModeClick(Sender: TObject);
    procedure ProgressTrackResize(Sender: TObject);
    procedure SourceFolderChanging(Sender: TObject; var CanChange: Boolean);
    procedure StartClick(Sender: TObject);
    procedure CancelClick(Sender: TObject);
    procedure PollTimerTimer(Sender: TObject);
    procedure ThreadsChange(Sender: TObject);
    procedure UpdateAutoThreads;
    procedure SetBusy(const Busy: Boolean);
    procedure SetPanelButtonEnabled(const Button: TPanel; const Enabled, Primary: Boolean);
    procedure SetProgressVisual(const Percent: Integer; const IsError: Boolean);
    procedure ResetActivityState;
    procedure SetInlineStatus(const StatusText: string; const IsError: Boolean;
      const DetailsText: string = '');
    procedure SetOutputPathText(const Value: string; const AutoGenerated: Boolean);
    procedure ShowErrorDialog(const MessageText: string;const DiagnosticDetails:string='');
    procedure ReportException(const Error:Exception);
    function ShowSourceBrowser(out SelectedPath: string): Boolean;
    procedure ShowTitleSystemMenu(const ScreenPoint: TPoint);
    procedure TitleBarContextPopup(Sender: TObject; MousePos: TPoint; var Handled: Boolean);
    procedure UpdateDefaultOutputPath(const Force: Boolean);
    procedure UpdateModeButtons;
    procedure UpdateOptionButtons;
    procedure UpdateStartState;
    procedure CloseStreams;
    function BuildTempOutputPath(const FinalPath: string): string;
    procedure FinalizeOutputFile;
    procedure CleanupOutputFile;
    procedure ApplyDwmWindowAttributes;
    procedure UpdateProgressUi(const InBytes, OutBytes: UInt64);
    procedure FinishTask(const ErrorText: string; const Cancelled: Boolean = False;
      const DiagnosticDetails:string='');
    procedure ClearTaskbarProgress;
    procedure InitializeShellIntegration;
    procedure InitializeTaskbarList;
    procedure LoadApplicationIcon;
    procedure MinimizeToTaskbar;
    procedure SetTaskbarProgress(const Percent: Integer; const IsError: Boolean);
  protected
    procedure CreateWnd; override;
    procedure DestroyWnd; override;
    procedure CreateParams(var Params: TCreateParams); override;
    procedure Resize; override;
    procedure TitleBarMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure TitleBarMouseUp(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure WndProc(var Message: TMessage); override;
    procedure WMNCActivate(var Message: TMessage); message WM_NCACTIVATE;
    procedure WMNCCalcSize(var Message: TWMNCCalcSize); message WM_NCCALCSIZE;
    procedure WMNCHitTest(var Message: TWMNCHitTest); message WM_NCHITTEST;
    procedure WMNCPaint(var Message: TMessage); message WM_NCPAINT;
  public
{$IFDEF GUI_LAYOUT_QA}
    procedure RunLayoutAudit(const Destination: string);
{$ENDIF}
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure ScaleForPPI(NewPPI: Integer); override;
  end;

var
  MainForm: TMainForm;

implementation

uses Lzma2LanguagePicker, Lzma2GuiResources, Lzma2GuiCatalog, Lzma2GuiSettings,
  Lzma2GuiEditHints,Lzma2GuiErrors,Lzma2GuiHints,Vcl.Clipbrd;

type
  TGuiModalForm = class(TForm)
  private
    FLogicalFonts: TArray<TGuiFontMetric>;
  protected
    procedure WndProc(var Message: TMessage); override;
  public
    procedure UseFont(const AFont:TFont; const TextHeight:Integer; const Semibold:Boolean=False);
    procedure UpdateRegion;
  end;

  TDialogCopyReport=class(TComponent)
  public
    Text:string;
    procedure CopyReport(Sender:TObject);
  end;

procedure TDialogCopyReport.CopyReport(Sender:TObject);
begin Clipboard.AsText:=Text;end;

const
  UiBackground = TColor($0016100B);
  UiChrome = TColor($001D1612);
  UiSurface = TColor($00271F1A);
  UiSurfaceAlt = TColor($003B2F25);
  UiSurfaceHigh = TColor($00493B30);
  UiSelection = TColor($00533E27);
  UiSelectionBorder = TColor($00967B5C);
  UiInput = TColor($00201812);
  UiInputDisabled = TColor($002C231D);
  UiBorder = TColor($007D6B5A);
  UiText = TColor($00F8F5F2);
  UiMutedText = TColor($00D4C8BE);
  UiSubtleText = TColor($00AF9F92);
  UiAccent = TColor($00FCBF78);
  UiAccentHover = TColor($00F8C98E);
  UiAccentText = UiInput;
  UiDanger = TColor($005858E8);
  UiSuccess = TColor($007AC155);
  UiWindowCloseHover = TColor($005252E1);
  UiDefaultWidth = 896;
  UiDefaultHeight = 520;
  UiMinimumWidth = 720;
  UiMinimumHeight = 344;
  UiHeaderHeight = 36;
  UiResizeGripSize = 16;
  UiContentPadding = 24;
  UiBottomPadding = 20;
  UiGap = 16;
  UiLabelHeight = 20;
  UiLabelGap = 8;
  UiFieldTop = UiLabelHeight + UiLabelGap;
  UiOptionHeight = 36;
  UiOptionArrowWidth = 32;
  UiModeTop = 52;
  UiActivityHeight = 68;
  UiActionInset = 12;
  UiBenchmarkHeight = 380;
  UiSmallText = 12;
  UiBodyText = 14;
  UiTitleText = 16;
  UiDialogTitleText = 18;
  UiModalSurface = UiSurfaceAlt;
  UiModalBorder = UiSelectionBorder;
  UiModalCornerRadius = 7;

  AppIconResourceName = 'MAINICON';
  TaskbarButtonCreatedMessageName = 'TaskbarButtonCreated';
var
  DictionaryMbValues, BenchmarkDictionaryMb, BenchmarkPassCounts: TArray<Integer>;
  GuiLanguageCodes: array[TGuiLanguage] of string;
  GuiLanguageNames: array[TGuiLanguage] of string;

procedure SetLogicalFont(const AFont: TFont; const TextHeight: Integer;
  const Semibold: Boolean = False);
begin
  // Runtime-created fonts start at the system DPI even while the form is at 96.
  AFont.PixelsPerInch := 96;
  if Semibold then
    AFont.Name := 'Segoe UI Semibold'
  else
    AFont.Name := 'Segoe UI';
  AFont.Style := [];
  AFont.Height := -TextHeight;
end;

procedure RegisterLogicalFont(var Fonts: TArray<TGuiFontMetric>; const AFont: TFont;
  const TextHeight: Integer; const Semibold: Boolean=False);
var Metric: TGuiFontMetric;
begin
  SetLogicalFont(AFont, TextHeight, Semibold);
  Metric.Font := AFont;
  Metric.LogicalHeight := TextHeight;
  Fonts := Fonts + [Metric];
end;

procedure ApplyLogicalFontHeights(const Fonts: TArray<TGuiFontMetric>; const Dpi: Integer);
begin
  // Scaling the last rounded pixel height repeatedly can accumulate error.
  for var Metric in Fonts do
    Metric.Font.Height := -MulDiv(Metric.LogicalHeight,Dpi,96);
end;

procedure TGuiModalForm.UseFont(const AFont:TFont; const TextHeight:Integer; const Semibold:Boolean);
begin
  RegisterLogicalFont(FLogicalFonts,AFont,TextHeight,Semibold);
end;

procedure TGuiModalForm.UpdateRegion;
var Diameter: Integer;
    Region: HRGN;
begin
  ApplyLogicalFontHeights(FLogicalFonts,PixelsPerInch);
  Diameter := ScaleValue(UiModalCornerRadius*2);
  Region := CreateRoundRectRgn(0,0,Width+1,Height+1,Diameter,Diameter);
  if (Region<>0) and (SetWindowRgn(Handle,Region,True)=0) then
    DeleteObject(Region);
end;

procedure TGuiModalForm.WndProc(var Message: TMessage);
begin
  inherited;
  if Message.Msg=WM_DPICHANGED then UpdateRegion;
end;

function GuiNativeEditHeight(const Font:TFont):Integer;
var DC:HDC;Previous:HGDIOBJ;Metrics:TTextMetric;
begin
  DC:=GetDC(0);
  if DC=0 then RaiseLastOSError;
  try
    Previous:=SelectObject(DC,Font.Handle);
    try
      if not GetTextMetrics(DC,Metrics) then RaiseLastOSError;
      // Borderless EDITs need caret clearance, not VCL's six-pixel frame
      // allowance. Center this actual line box in the surrounding field.
      Result:=Metrics.tmHeight+2;
    finally SelectObject(DC,Previous);end;
  finally ReleaseDC(0,DC);end;
end;

{$I Lzma2ThreadChoiceMethods.inc}

function GuiProductName: string;
begin Result:=GuiApplicationValue('name');end;
function GuiProductVersion: string;
begin Result:=GuiApplicationValue('version');end;
function GuiSdkTarget: string;
begin Result:=GuiApplicationValue('sdkVersion');end;
function GuiProjectUrl: string;
begin Result:=GuiApplicationValue('repository');end;

function GuiLanguageFromLangId(const LangId: LANGID): TGuiLanguage;
const
  PrimaryLanguageMask = $03FF;
  LangBulgarian = $02;
  LangChinese = $04;
  LangCzech = $05;
  LangDanish = $06;
  LangGerman = $07;
  LangGreek = $08;
  LangEnglish = $09;
  LangSpanish = $0A;
  LangFinnish = $0B;
  LangFrench = $0C;
  LangHungarian = $0E;
  LangItalian = $10;
  LangJapanese = $11;
  LangKorean = $12;
  LangDutch = $13;
  LangNorwegian = $14;
  LangPolish = $15;
  LangPortuguese = $16;
  LangRomanian = $18;
  LangRussian = $19;
  LangSwedish = $1D;
  LangTurkish = $1F;
  LangUkrainian = $22;
  SubLangBrazilian = $01;
var
  PrimaryLanguage: Word;
  SubLanguage: Word;
begin
  PrimaryLanguage := LangId and PrimaryLanguageMask;
  SubLanguage := LangId shr 10;
  case PrimaryLanguage of
    LangBulgarian: Result := glBulgarian;
    LangChinese: Result := glChineseSimplified;
    LangCzech: Result := glCzech;
    LangDanish: Result := glDanish;
    LangGerman: Result := glGerman;
    LangGreek: Result := glGreek;
    LangEnglish: Result := glEnglish;
    LangSpanish: Result := glSpanish;
    LangFinnish: Result := glFinnish;
    LangFrench: Result := glFrench;
    LangHungarian: Result := glHungarian;
    LangItalian: Result := glItalian;
    LangJapanese: Result := glJapanese;
    LangKorean: Result := glKorean;
    LangDutch: Result := glDutch;
    LangNorwegian: Result := glNorwegian;
    LangPolish: Result := glPolish;
    LangPortuguese:
      if SubLanguage = SubLangBrazilian then
        Result := glBrazilian
      else
        Result := glPortuguese;
    LangRomanian: Result := glRomanian;
    LangRussian: Result := glRussian;
    LangSwedish: Result := glSwedish;
    LangTurkish: Result := glTurkish;
    LangUkrainian: Result := glUkrainian;
  else
    Result := glEnglish;
  end;
end;

function DetectGuiLanguage: TGuiLanguage;
begin
  Result := GuiLanguageFromLangId(GetUserDefaultUILanguage);
end;

function GuiLanguagePreferencePath: string;
begin Result:=GuiSettingsPath;end;

constructor TOptionCombo.Create(AOwner: TComponent);
begin
  inherited;
  FControlBuffer:=TBitmap.Create;
  FControlBuffer.PixelFormat:=pf32bit;
  Style := csOwnerDrawFixed;
  Color := UiInput;
  SetLogicalFont(Font, UiBodyText);
  Font.Color := UiText;
  ItemHeight := GuiPopupRowHeight;
  DropDownCount := GuiPopupVisibleRows;
  StyleElements := [];
end;

destructor TOptionCombo.Destroy;
begin
  try inherited;
  finally FControlBuffer.Free;end;
end;

function TOptionCombo.ArrowBounds: TRect;
begin
  Result:=ClientRect;
  Result.Left:=Max(Result.Left,Result.Right-ScaleValue(UiOptionArrowWidth));
end;

procedure TOptionCombo.CreateWnd;
var Info: TComboBoxInfo;
    Colors: TGuiListColors;
begin
  inherited;
  SetWindowTheme(Handle, 'DarkMode_CFD', nil);
  UpdateSelectionFieldHeight;
  Info.cbSize:=SizeOf(Info);
  if GetComboBoxInfo(Handle,Info) and (Info.hwndList<>0) then
  begin
    Colors.Background:=UiInput;Colors.Text:=UiText;Colors.Muted:=UiSubtleText;
    Colors.Selection:=UiSelection;Colors.Hover:=UiSurfaceAlt;Colors.Accent:=UiAccent;
    FListPresenter:=TNativeListPresenter.CreateForList(Self,Info.hwndList,
      PixelsPerInch,Colors,PaintListItem);
  end;
end;

procedure TOptionCombo.DestroyWnd;
begin
  FArrowPressed:=False;FArrowHover:=False;
  FreeAndNil(FListPresenter);
  inherited;
end;

procedure TOptionCombo.ChangeScale(M, D: Integer; isDpiChange: Boolean);
begin
  inherited;
  if isDpiChange then Font.Height := -MulDiv(UiBodyText,M,96);
  UpdateSelectionFieldHeight;
  if FListPresenter<>nil then FListPresenter.Refresh(PixelsPerInch);
end;

procedure TOptionCombo.UpdateSelectionFieldHeight;
var
  WindowRect: TRect;
  FieldHeight: Integer;
  NativeTrim: Integer;
  TargetFieldHeight: Integer;
begin
  if not HandleAllocated then
    Exit;
  FieldHeight := Integer(Perform(CB_GETITEMHEIGHT, High(WPARAM), 0));
  if (FieldHeight = CB_ERR) or not GetWindowRect(Handle, WindowRect) then
    Exit;
  // Windows sizes the closed field independently of the dropdown rows.
  NativeTrim := WindowRect.Height - FieldHeight;
  if NativeTrim < 0 then
    Exit;
  TargetFieldHeight := Max(ItemHeight, ScaleValue(UiOptionHeight) - NativeTrim);
  if TargetFieldHeight <> FieldHeight then
    Perform(CB_SETITEMHEIGHT, High(WPARAM), TargetFieldHeight);
end;

function TOptionCombo.InputInvalid: Boolean;
begin Result:=False;end;

procedure TOptionCombo.PaintControl(const DC: HDC);
var
  TargetCanvas: TCanvas;
  D2D: TDirect2DCanvas;
  Bounds: TD2D1RoundedRect;
  TextBounds: TRect;
  TextFormat: TTextFormat;
  Text: string;
  BorderColor: TColor;
  Foreground: TColor;
  ArrowX: Single;
  ArrowY: Single;
begin
  if (ClientWidth<=0) or (ClientHeight<=0) then Exit;
  if (FControlBuffer.Width<>ClientWidth) or (FControlBuffer.Height<>ClientHeight) then
    FControlBuffer.SetSize(ClientWidth,ClientHeight);
  TargetCanvas:=FControlBuffer.Canvas;
  TargetCanvas.Lock;
  try
    // Notify the bitmap canvas of the modification before lending its DC to
    // Direct2D, and keep that DC valid through the final opaque copy.
    TargetCanvas.Brush.Color:=Color;
    TargetCanvas.FillRect(ClientRect);
    D2D := TDirect2DCanvas.Create(TargetCanvas, ClientRect);
    try
      D2D.BeginDraw;
      try
        D2D.RenderTarget.SetDpi(96, 96);
        D2D.RenderTarget.SetAntialiasMode(D2D1_ANTIALIAS_MODE_PER_PRIMITIVE);
        D2D.RenderTarget.SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
        if Parent is TPanel then
          D2D.RenderTarget.Clear(D2D1ColorF(TPanel(Parent).Color))
        else
          D2D.RenderTarget.Clear(D2D1ColorF(UiSurface));
        if not Enabled then
          Foreground := UiSubtleText
        else
          Foreground := UiText;
        if InputInvalid then
          BorderColor := UiDanger
        else if Focused then
          BorderColor := UiAccent
        else
          BorderColor := UiBorder;
        Bounds := D2D1RoundedRect(D2D1RectF(0.5, 0.5,
          ClientWidth - 0.5, ClientHeight - 0.5), ScaleValue(6), ScaleValue(6));
        if Enabled and FHover and (Style<>csDropDown) then
          D2D.Brush.Color := UiSurfaceAlt
        else
          D2D.Brush.Color := UiInput;
        D2D.FillRoundedRectangle(Bounds);
        if Enabled and (Style=csDropDown) and (FArrowHover or FArrowPressed) then
        begin
          D2D.RenderTarget.PushAxisAlignedClip(D2D1RectF(ArrowBounds.Left,0,
            ClientWidth,ClientHeight),D2D1_ANTIALIAS_MODE_PER_PRIMITIVE);
          try
            D2D.Brush.Color:=UiSurfaceAlt;
            D2D.FillRoundedRectangle(Bounds);
          finally D2D.RenderTarget.PopAxisAlignedClip;end;
        end;
        D2D.Pen.Color := BorderColor;
        D2D.RenderTarget.DrawRoundedRectangle(Bounds, D2D.Pen.Brush.Handle, ScaleValue(1.0));
        D2D.Font.Assign(Font);
        D2D.Font.Color := Foreground;
        D2D.Brush.Style := bsClear;
        TextBounds := Rect(ScaleValue(12), 0,
          ClientWidth - ScaleValue(UiOptionArrowWidth), ClientHeight);
        TextFormat := [tfLeft, tfSingleLine, tfVerticalCenter, tfNoPrefix, tfEndEllipsis];
        if (ItemIndex >= 0) and (ItemIndex < Items.Count) then
          Text := Items[ItemIndex]
        else
          Text := '';
        if Style<>csDropDown then D2D.TextRect(TextBounds, Text, TextFormat);
        D2D.Pen.Color := Foreground;
        ArrowX := (ArrowBounds.Left+ArrowBounds.Right)*0.5;
        ArrowY := ClientHeight * 0.5;
        D2D.RenderTarget.DrawLine(D2D1PointF(ArrowX - ScaleValue(4), ArrowY - ScaleValue(2)),
          D2D1PointF(ArrowX, ArrowY + ScaleValue(2)), D2D.Pen.Brush.Handle, ScaleValue(1.25));
        D2D.RenderTarget.DrawLine(D2D1PointF(ArrowX, ArrowY + ScaleValue(2)),
          D2D1PointF(ArrowX + ScaleValue(4), ArrowY - ScaleValue(2)),
          D2D.Pen.Brush.Handle, ScaleValue(1.25));
      finally
        D2D.EndDraw;
      end;
    finally
      D2D.Free;
    end;
  BitBlt(DC,0,0,ClientWidth,ClientHeight,TargetCanvas.Handle,0,0,SRCCOPY);
  finally TargetCanvas.Unlock;end;
end;

procedure TOptionCombo.WMPaint(var Message: TWMPaint);
var
  PaintStruct: TPaintStruct;
  DC: HDC;
begin
  if not TDirect2DCanvas.Supported then
  begin
    inherited;
    Exit;
  end;
  DC := Message.DC;
  if DC = 0 then
    DC := BeginPaint(Handle, PaintStruct);
  try
    PaintControl(DC);
  finally
    if Message.DC = 0 then
      EndPaint(Handle, PaintStruct);
  end;
end;

procedure TOptionCombo.WMPrintClient(var Message: TWMPrintClient);
begin
  if not TDirect2DCanvas.Supported then
  begin
    inherited;
    Exit;
  end;
  PaintControl(Message.DC);
  Message.Result := 1;
end;

procedure TOptionCombo.WndProc(var Message: TMessage);
var P:TPoint;Hovered,OpenPopup:Boolean;
begin
  if (Message.Msg=WM_ERASEBKGND) and TDirect2DCanvas.Supported then
  begin Message.Result:=1;Exit;end;
  if Message.Msg=WM_CAPTURECHANGED then
  begin FArrowPressed:=False;Invalidate;end;
  if (Style=csDropDown) and Enabled then
  begin
    if Message.Msg=WM_MOUSEMOVE then
    begin
      P:=Point(SmallInt(LoWord(Message.LParam)),SmallInt(HiWord(Message.LParam)));
      Hovered:=ArrowBounds.Contains(P);
      if Hovered<>FArrowHover then begin FArrowHover:=Hovered;Invalidate;end;
    end;
    if (Message.Msg=WM_LBUTTONDOWN) and not DroppedDown then
    begin
      P:=Point(SmallInt(LoWord(Message.LParam)),SmallInt(HiWord(Message.LParam)));
      if ArrowBounds.Contains(P) then
      begin
        SetFocus;MouseCapture:=True;FArrowPressed:=True;
        Invalidate;Message.Result:=0;Exit;
      end;
    end;
    if (Message.Msg=WM_LBUTTONUP) and FArrowPressed then
    begin
      P:=Point(SmallInt(LoWord(Message.LParam)),SmallInt(HiWord(Message.LParam)));
      OpenPopup:=ArrowBounds.Contains(P);
      FArrowPressed:=False;MouseCapture:=False;
      if OpenPopup then DroppedDown:=True;
      Invalidate;Message.Result:=0;Exit;
    end;
  end;
  // The editable combo's VCL child already requests popup keys. A readonly
  // owner-drawn combo receives this query on the combo window itself.
  if (Message.Msg=WM_GETDLGCODE) and DroppedDown then
  begin Message.Result:=DLGC_WANTALLKEYS;Exit;end;
  if (Message.Msg=CN_COMMAND) and (HiWord(Message.WParam)=CBN_DROPDOWN) and
    (FListPresenter<>nil) then
  begin Application.CancelHint;FListPresenter.PrepareOpen;end;
  inherited;
  if (Message.Msg=CN_COMMAND) and (HiWord(Message.WParam)=CBN_DROPDOWN) and
    (FListPresenter<>nil) then FListPresenter.Refresh(PixelsPerInch);
  case Message.Msg of
    CM_FONTCHANGED:
      UpdateSelectionFieldHeight;
    WM_SETFOCUS, WM_KILLFOCUS, CM_ENABLEDCHANGED, CN_COMMAND:
      Invalidate;
  end;
end;

procedure TOptionCombo.CMMouseEnter(var Message: TMessage);
begin
  inherited;
  FHover := True;
  Invalidate;
end;

procedure TOptionCombo.CMMouseLeave(var Message: TMessage);
begin
  inherited;
  FHover := False;
  FArrowHover:=False;
  Invalidate;
end;

procedure TOptionCombo.DrawItem(Index: Integer; Rect: TRect; State: TOwnerDrawState);
begin
  if odComboBoxEdit in State then
  begin
    // PaintControl owns the whole closed field, including its chevron. Native
    // selection-field drawing would cover half of the DPI-scaled chevron.
    Invalidate;
    Exit;
  end;
  PaintListItem(Canvas,Index,Rect,odSelected in State);
end;

procedure TOptionCombo.PaintListItem(const Canvas:TCanvas;const Index:Integer;
  const Bounds:TRect;const Selected:Boolean);
var TextBounds:TRect;Text:string;
begin
  Canvas.Font.Assign(Font);
  if Selected then Canvas.Brush.Color:=UiSurfaceHigh
  else Canvas.Brush.Color:=Color;
  if Enabled then Canvas.Font.Color:=UiText
  else Canvas.Font.Color:=UiSubtleText;
  Canvas.FillRect(Bounds);TextBounds:=Bounds;
  Inc(TextBounds.Left,ScaleValue(10));Dec(TextBounds.Right,ScaleValue(8));
  if (Index>=0) and (Index<Items.Count) then
  begin
    Text:=Items[Index];
    Canvas.TextRect(TextBounds,Text,
      [tfLeft,tfSingleLine,tfVerticalCenter,tfNoPrefix,tfEndEllipsis]);
  end;
end;

constructor TRoundedPanel.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  BevelOuter := bvNone;
  BorderStyle := bsNone;
  Ctl3D := False;
  DoubleBuffered := True;
  ParentBackground := False;
  StyleElements := [];
  FCornerRadius := 8;
  FBorderColor := UiBorder;
  FBorderWidth := 1;
  FCaptionOffsetY := 0;
  FGradientToColor := clNone;
  FHoverColor := clNone;
  FGlyphKind := pgNone;
  FUseGradient := False;
end;

procedure TRoundedPanel.CreateParams(var Params:TCreateParams);
begin
  inherited;
  Params.Style:=Params.Style or WS_CLIPCHILDREN;
end;

procedure TRoundedPanel.CreateWnd;
begin
  inherited;
  UpdateRegion;
end;

procedure TRoundedPanel.Paint;
var
  D2D: TDirect2DCanvas;
  BackColor: TColor;
  FillColor: TColor;
  GradientColor: TColor;
  PaintBorder: TColor;
  PaintBorderWidth: Single;
  CaptionRect: TRect;
  TextFormat: TTextFormat;
  CaptionText: string;
  GlyphGap: Integer;
  GlyphLeft: Single;
  GlyphSize: Integer;
  GlyphTop: Single;
  Padding: Integer;
  Radius: Single;
  StrokeWidth: Single;
  TextBlockWidth: Integer;
  TextWidth: Integer;
  Pressed: Boolean;
  Bounds: TD2D1RoundedRect;
begin
  if (ClientWidth <= 0) or (ClientHeight <= 0) then
    Exit;
  if not TDirect2DCanvas.Supported then
  begin
    inherited;
    Exit;
  end;

  BackColor := Color;
  if Parent is TCustomForm then
    BackColor := TCustomForm(Parent).Color
  else if Parent is TPanel then
    BackColor := TPanel(Parent).Color;
  FillColor := Color;
  GradientColor := FGradientToColor;
  PaintBorder := FBorderColor;
  PaintBorderWidth := FBorderWidth;
  if Enabled and TabStop and FHasFocus and FShowKeyboardFocus then
  begin
    PaintBorder := UiAccentHover;
    PaintBorderWidth := 1;
  end;
  Pressed := Enabled and (FKeyPressed or (FMousePressed and FHover));
  if Enabled and Assigned(OnClick) then
  begin
    if Pressed then
    begin
      FillColor := ColorBlendRGB(Color, UiInput, 0.20);
      if GradientColor <> clNone then
        GradientColor := ColorBlendRGB(GradientColor, UiInput, 0.20);
    end
    else if FHover and (FHoverColor <> clNone) then
    begin
      FillColor := FHoverColor;
      if FUseGradient then
        GradientColor := FHoverColor;
    end;
  end;

  D2D := TDirect2DCanvas.Create(Canvas, ClientRect);
  try
    D2D.BeginDraw;
    try
      D2D.RenderTarget.SetDpi(96, 96);
      D2D.RenderTarget.SetAntialiasMode(D2D1_ANTIALIAS_MODE_PER_PRIMITIVE);
      D2D.RenderTarget.SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
      D2D.RenderTarget.Clear(D2D1ColorF(BackColor));
      Radius := Max(0, ScaleValue(Double(FCornerRadius)));
      Bounds := D2D1RoundedRect(D2D1RectF(0.5, 0.5, ClientWidth - 0.5,
        ClientHeight - 0.5), Radius, Radius);
      if FUseGradient and (GradientColor <> clNone) then
        D2D.Brush.Handle := D2D.CreateBrush([FillColor, GradientColor],
          D2D1PointF(0, 0), D2D1PointF(0, ClientHeight))
      else
        D2D.Brush.Color := FillColor;
      D2D.FillRoundedRectangle(Bounds);
      if (PaintBorderWidth > 0) and (PaintBorder <> clNone) then
      begin
        D2D.Pen.Color := PaintBorder;
        D2D.Pen.Brush.Handle.SetOpacity($9A / $FF);
        StrokeWidth := ScaleValue(Double(PaintBorderWidth));
        D2D.RenderTarget.DrawRoundedRectangle(Bounds, D2D.Pen.Brush.Handle, StrokeWidth);
      end;
      if Caption = '' then
        Exit;

      D2D.Font.Assign(Font);
      // The family already supplies the semibold face; do not synthesize bold again.
      if SameText(Font.Name, 'Segoe UI Semibold') then
        D2D.Font.Style := Font.Style - [fsBold];
      D2D.Brush.Style := bsClear;
      GlyphSize := 0;
      GlyphGap := 0;
      Padding := ScaleValue(14);
      if Alignment = taCenter then
        Padding := ScaleValue(2);
      if FGlyphKind <> pgNone then
      begin
        GlyphSize := Min(ScaleValue(20), Max(ScaleValue(16), ClientHeight - ScaleValue(24)));
        GlyphGap := ScaleValue(8);
      end;
      TextWidth := Min(D2D.TextWidth(Caption),
        Max(0, ClientWidth - Padding * 2 - GlyphSize - GlyphGap));
      TextBlockWidth := TextWidth + GlyphSize + GlyphGap;
      case Alignment of
        taRightJustify:
          GlyphLeft := ClientWidth - TextBlockWidth - Padding;
        taCenter:
          GlyphLeft := (ClientWidth - TextBlockWidth) * 0.5;
      else
        GlyphLeft := Padding;
      end;
      if FGlyphKind <> pgNone then
      begin
        GlyphTop := (ClientHeight - GlyphSize) * 0.5;
        D2D.Pen.Color := Font.Color;
        D2D.Pen.Brush.Handle.SetOpacity(1);
        case FGlyphKind of
          pgFile:
            begin
              D2D.RenderTarget.DrawRoundedRectangle(D2D1RoundedRect(
                D2D1RectF(GlyphLeft + ScaleValue(3), GlyphTop + ScaleValue(1),
                  GlyphLeft + GlyphSize - ScaleValue(2), GlyphTop + GlyphSize - ScaleValue(1)),
                ScaleValue(1.5), ScaleValue(1.5)), D2D.Pen.Brush.Handle, ScaleValue(1.45));
              D2D.RenderTarget.DrawLine(D2D1PointF(GlyphLeft + GlyphSize - ScaleValue(6), GlyphTop + ScaleValue(1)),
                D2D1PointF(GlyphLeft + GlyphSize - ScaleValue(6), GlyphTop + ScaleValue(5)),
                D2D.Pen.Brush.Handle, ScaleValue(1.45));
              D2D.RenderTarget.DrawLine(D2D1PointF(GlyphLeft + GlyphSize - ScaleValue(6), GlyphTop + ScaleValue(5)),
                D2D1PointF(GlyphLeft + GlyphSize - ScaleValue(2), GlyphTop + ScaleValue(5)),
                D2D.Pen.Brush.Handle, ScaleValue(1.45));
            end;
          pgLanguage:
            begin
              D2D.RenderTarget.DrawEllipse(D2D1Ellipse(
                D2D1PointF(GlyphLeft + GlyphSize * 0.5, GlyphTop + GlyphSize * 0.5),
                GlyphSize * 0.45, GlyphSize * 0.45),
                D2D.Pen.Brush.Handle, ScaleValue(1.25));
              D2D.RenderTarget.DrawEllipse(D2D1Ellipse(
                D2D1PointF(GlyphLeft + GlyphSize * 0.5, GlyphTop + GlyphSize * 0.5),
                GlyphSize * 0.20, GlyphSize * 0.45),
                D2D.Pen.Brush.Handle, ScaleValue(1.25));
              D2D.RenderTarget.DrawLine(
                D2D1PointF(GlyphLeft + GlyphSize * 0.05, GlyphTop + GlyphSize * 0.5),
                D2D1PointF(GlyphLeft + GlyphSize * 0.95, GlyphTop + GlyphSize * 0.5),
                D2D.Pen.Brush.Handle, ScaleValue(1.25));
            end;
          pgFolder:
            begin
              D2D.RenderTarget.DrawLine(D2D1PointF(GlyphLeft + ScaleValue(2), GlyphTop + ScaleValue(5)),
                D2D1PointF(GlyphLeft + ScaleValue(6), GlyphTop + ScaleValue(2)),
                D2D.Pen.Brush.Handle, ScaleValue(1.45));
              D2D.RenderTarget.DrawLine(D2D1PointF(GlyphLeft + ScaleValue(6), GlyphTop + ScaleValue(2)),
                D2D1PointF(GlyphLeft + ScaleValue(10), GlyphTop + ScaleValue(5)),
                D2D.Pen.Brush.Handle, ScaleValue(1.45));
              D2D.RenderTarget.DrawRoundedRectangle(D2D1RoundedRect(
                D2D1RectF(GlyphLeft + ScaleValue(1), GlyphTop + ScaleValue(5),
                  GlyphLeft + GlyphSize - ScaleValue(1), GlyphTop + GlyphSize - ScaleValue(1)),
                ScaleValue(2), ScaleValue(2)), D2D.Pen.Brush.Handle, ScaleValue(1.45));
            end;
        end;
      end;
      CaptionRect := Rect(Round(GlyphLeft + GlyphSize + GlyphGap), 0,
        ClientWidth - Padding, ClientHeight);
      TextFormat := [tfLeft, tfSingleLine, tfVerticalCenter, tfEndEllipsis, tfNoPrefix];
      if FGlyphKind = pgNone then
      begin
        CaptionRect.Left := Padding;
        case Alignment of
          taCenter: Include(TextFormat, tfCenter);
          taRightJustify: Include(TextFormat, tfRight);
        end;
      end;
      OffsetRect(CaptionRect, 0, Round(ScaleValue(Double(FCaptionOffsetY))) + Ord(Pressed) * ScaleValue(1));
      CaptionText := Caption;
      D2D.TextRect(CaptionRect, CaptionText, TextFormat);
    finally
      D2D.EndDraw;
    end;
  finally
    D2D.Free;
  end;
end;
procedure TRoundedPanel.Resize;
begin
  inherited;
  UpdateRegion;
end;

procedure TRoundedPanel.UpdateRegion;
begin
  // Keep a rectangular backing so antialiasing can blend into the parent surface.
  if HandleAllocated then
    SetWindowRgn(Handle, 0, True);
end;

procedure TRoundedPanel.CMMouseEnter(var Message: TMessage);
begin
  inherited;
  if not FHover then
  begin
    FHover:=True;
    if (FHoverColor<>clNone) or FMousePressed then Invalidate;
  end;
end;

procedure TRoundedPanel.CMDialogKey(var Message: TCMDialogKey);
begin
  if Enabled and TabStop and FHasFocus and Assigned(OnClick) and
    (Message.CharCode = VK_RETURN) and (KeyDataToShiftState(Message.KeyData) = []) then
  begin
    FShowKeyboardFocus := True;
    Click;
    Message.Result := 1;
  end
  else
    inherited;
end;

procedure TRoundedPanel.CMMouseLeave(var Message: TMessage);
begin
  inherited;
  if FHover then
  begin
    FHover:=False;
    if (FHoverColor<>clNone) or FMousePressed then Invalidate;
  end;
end;

procedure TRoundedPanel.WMCaptureChanged(var Message: TMessage);
begin
  inherited;
  FMousePressed := False;
  Invalidate;
end;

procedure TRoundedPanel.DoEnter;
begin
  inherited;
  FHasFocus := True;
  FShowKeyboardFocus := not FMousePressed;
  Invalidate;
end;

procedure TRoundedPanel.DoExit;
begin
  inherited;
  FHasFocus := False;
  FKeyPressed := False;
  Invalidate;
end;

procedure TRoundedPanel.FocusWithCue(const Keyboard: Boolean);
begin
  FMousePressed:=not Keyboard;
  try
    if CanFocus then SetFocus;
  finally FMousePressed:=False;end;
  FShowKeyboardFocus:=Keyboard;
  Invalidate;
end;

procedure TRoundedPanel.KeyDown(var Key: Word; Shift: TShiftState);
begin
  inherited;
  FShowKeyboardFocus := True;
  Invalidate;
  if Enabled and TabStop and Assigned(OnClick) and (Shift = []) then
    case Key of
      VK_SPACE:
        begin
          FKeyPressed := True;
          Key := 0;
          Invalidate;
        end;
      VK_RETURN:
        begin
          Key := 0;
          Click;
        end;
    end;
end;

procedure TRoundedPanel.KeyUp(var Key: Word; Shift: TShiftState);
begin
  inherited;
  if Key = VK_SPACE then
  begin
    if FKeyPressed then
    begin
      FKeyPressed := False;
      Invalidate;
      Key := 0;
      if Enabled and TabStop and Assigned(OnClick) then
        Click;
    end;
  end;
end;

procedure TRoundedPanel.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  if (Button = mbLeft) and Enabled and Assigned(OnClick) then
  begin
    FShowKeyboardFocus := False;
    FMousePressed := True;
    if Showing and CanFocus then
      SetFocus;
    Invalidate;
  end;
  inherited;
end;

procedure TRoundedPanel.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  FMousePressed := False;
  Invalidate;
  inherited;
end;
constructor TWindowButton.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Width := 46;
  Height := 42;
  Color := UiChrome;
  ParentColor := False;
  Cursor := crHandPoint;
  DoubleBuffered := True;
  StyleElements := [];
end;

procedure TWindowButton.CreateWnd;
begin
  inherited;
  SetWindowRgn(Handle, 0, True);
end;

procedure TWindowButton.Resize;
begin
  inherited;
  if HandleAllocated then
    SetWindowRgn(Handle, 0, True);
end;

procedure TWindowButton.CMMouseEnter(var Message: TMessage);
begin
  inherited;
  FHover := True;
  Invalidate;
end;

procedure TWindowButton.CMMouseLeave(var Message: TMessage);
begin
  inherited;
  FHover := False;
  Invalidate;
end;

procedure TWindowButton.Paint;
var
  BackColor: TColor;
  CX: Single;
  CY: Single;
  S: Single;
  StrokeWidth: Single;
  D2D: TDirect2DCanvas;
begin
  if (ClientWidth <= 0) or (ClientHeight <= 0) then
    Exit;
  if not TDirect2DCanvas.Supported then
  begin
    inherited;
    Exit;
  end;
  if FHover then
  begin
    if FKind = wbClose then
      BackColor := UiWindowCloseHover
    else
      BackColor := UiSurfaceAlt;
  end
  else
    BackColor := Color;

  D2D := TDirect2DCanvas.Create(Canvas, ClientRect);
  try
    D2D.BeginDraw;
    try
      D2D.RenderTarget.SetDpi(96, 96);
      D2D.RenderTarget.Clear(D2D1ColorF(Color));
      if BackColor<>Color then
      begin
        D2D.Brush.Color:=BackColor;
        D2D.FillRoundedRectangle(D2D1RoundedRect(
          D2D1RectF(0,0,ClientWidth,ClientHeight),ScaleValue(FCornerRadius),ScaleValue(FCornerRadius)));
      end;
      D2D.Pen.Color := UiMutedText;
      if (FKind = wbClose) and FHover then
        D2D.Pen.Color := clWhite;
      CX := ClientWidth * 0.5;
      CY := ClientHeight * 0.5;
      S := ScaleValue(5);
      StrokeWidth := ScaleValue(1.0);
      case FKind of
        wbMinimize:
          D2D.RenderTarget.DrawLine(D2D1PointF(CX - S, CY + S * 0.5),
            D2D1PointF(CX + S, CY + S * 0.5), D2D.Pen.Brush.Handle, StrokeWidth);
        wbMaximize:
          if IsZoomed(GetAncestor(Handle, GA_ROOT)) then
          begin
            D2D.RenderTarget.DrawRectangle(
              D2D1RectF(CX - S + ScaleValue(3), CY - S,
                CX + S, CY + S - ScaleValue(3)), D2D.Pen.Brush.Handle, StrokeWidth);
            D2D.Brush.Color := BackColor;
            D2D.RenderTarget.FillRectangle(
              D2D1RectF(CX - S, CY - S + ScaleValue(3),
                CX + S - ScaleValue(3), CY + S), D2D.Brush.Handle);
            D2D.RenderTarget.DrawRectangle(
              D2D1RectF(CX - S, CY - S + ScaleValue(3),
                CX + S - ScaleValue(3), CY + S), D2D.Pen.Brush.Handle, StrokeWidth);
          end
          else
            D2D.RenderTarget.DrawRectangle(
              D2D1RectF(CX - S, CY - S, CX + S, CY + S),
              D2D.Pen.Brush.Handle, StrokeWidth);
        wbClose:
          begin
            D2D.RenderTarget.DrawLine(D2D1PointF(CX - S, CY - S),
              D2D1PointF(CX + S, CY + S), D2D.Pen.Brush.Handle, StrokeWidth);
            D2D.RenderTarget.DrawLine(D2D1PointF(CX + S, CY - S),
              D2D1PointF(CX - S, CY + S), D2D.Pen.Brush.Handle, StrokeWidth);
          end;
      end;
    finally
      D2D.EndDraw;
    end;
  finally
    D2D.Free;
  end;
end;
function ShellItemPath(const Item: IShellItem): string;
var
  DisplayName: LPCWSTR;
begin
  Result := '';
  DisplayName := nil;
  if (Item <> nil) and (Item.GetDisplayName(SIGDN_FILESYSPATH, DisplayName) = S_OK) then
  try
    Result := DisplayName;
  finally
    CoTaskMemFree(DisplayName);
  end;
end;

function DecodeFallbackReasonName(const Reason: TLzma2DecodeFallbackReason): string;
begin
  case Reason of
    ldfrNone: Result := 'none';
    ldfrThreadCountOne: Result := 'thread-count-one';
    ldfrNonSeekableStream: Result := 'non-seekable-stream';
    ldfrSingleIndependentUnit: Result := 'single-independent-unit';
    ldfrUnknownPackedSize: Result := 'unknown-packed-size';
    ldfrUnknownUnpackedSize: Result := 'unknown-unpacked-size';
    ldfrUnsupportedLayout: Result := 'unsupported-layout';
    ldfrMemoryLimit: Result := 'memory-limit';
    ldfrInsufficientWork: Result := 'insufficient-work';
  else
    Result := 'unknown';
  end;
end;

destructor TApplicationMark.Destroy;
begin
  if FResourceIcon<>0 then DestroyIcon(FResourceIcon);
  inherited;
end;

procedure TApplicationMark.Paint;
var NewIcon: HICON;
begin
  if (Width<=0) or (Height<=0) then Exit;
  if (FResourceIcon=0) or (FIconWidth<>Width) or (FIconHeight<>Height) then
  begin
    NewIcon := HICON(LoadImage(HInstance,PChar(AppIconResourceName),IMAGE_ICON,
      Width,Height,LR_DEFAULTCOLOR));
    if NewIcon<>0 then
    begin
      if FResourceIcon<>0 then DestroyIcon(FResourceIcon);
      FResourceIcon := NewIcon;
      FIconWidth := Width;
      FIconHeight := Height;
    end;
  end;
  Canvas.Brush.Color := Color;
  Canvas.FillRect(ClientRect);
  if FResourceIcon<>0 then
    DrawIconEx(Canvas.Handle,0,0,FResourceIcon,Width,Height,0,0,DI_NORMAL);
end;

procedure TGuiResizeGrip.Paint;
var
  Row, Column, X, Y, DotSize: Integer;
begin
  DotSize := ScaleValue(2);
  Canvas.Brush.Color := UiBorder;
  for Row := 0 to 2 do
  begin
    Y := Height - ScaleValue(14-Row*4);
    for Column := 0 to Row do
    begin
      X := Width - ScaleValue(6+Column*4);
      Canvas.FillRect(Rect(X, Y, X+DotSize, Y+DotSize));
    end;
  end;
end;

constructor TMainForm.Create(AOwner: TComponent);
var
  OleResult: HRESULT;
begin
  inherited CreateNew(AOwner);
  ScaleForPPI(96);
  Font.PixelsPerInch := 96;
  ConfigureGuiHints(UiModalSurface,UiModalBorder,UiText);
  OleResult := OleInitialize(nil);
  FOleInitialized := Succeeded(OleResult);
  FTaskbarButtonCreatedMessage := RegisterWindowMessage(TaskbarButtonCreatedMessageName);
  LoadLanguagePreference;
  BuildUi;
  ScaleForCurrentDpi;
  // CreateNew builds controls from logical pixels. VCL can retain zero cached
  // client extents while scaling them; assign both startup extents explicitly.
  ClientWidth := ScaleValue(UiDefaultWidth);
  ClientHeight := ScaleValue(UiDefaultHeight);
  ConstrainToWorkArea;
  LoadApplicationIcon;
  InitializeShellIntegration;
end;

destructor TMainForm.Destroy;
begin
  try SavePackingPreference;
  except OutputDebugString('LZMA2 GUI preferences could not be saved');end;
  if FBenchTimer <> nil then FBenchTimer.Enabled := False;
  FreeAndNil(FBenchBackend);
  ClearTaskbarProgress;
  TInterlocked.Exchange(FCancelRequested, 1);
  if FPollTimer <> nil then
    FPollTimer.Enabled := False;
  if FTask <> nil then
  begin
    try
      FTask.Wait;
    except
      // The form is closing; the status was already surfaced while the UI was alive.
    end;
    FTask := nil;
  end;
  CloseStreams;
  CleanupOutputFile;
  FTaskbarList := nil;
  inherited Destroy;
  FSmallWindowIcon.Free;
  if FOleInitialized then
    OleUninitialize;
end;

procedure TMainForm.CreateWnd;
begin
  inherited;
  LoadApplicationIcon;
  ApplyDwmWindowAttributes;
  InitializeShellIntegration;
  Resize;
end;

procedure TMainForm.DestroyWnd;
begin
  ClearTaskbarProgress;
  inherited;
end;

procedure TMainForm.CreateParams(var Params: TCreateParams);
begin
  inherited CreateParams(Params);
  Params.Style := (Params.Style and not WS_POPUP) or WS_OVERLAPPED or WS_CAPTION or
    WS_THICKFRAME or WS_SYSMENU or WS_MINIMIZEBOX or WS_MAXIMIZEBOX;
  Params.ExStyle := Params.ExStyle or WS_EX_APPWINDOW;
  Params.WndParent := 0;
end;

procedure TMainForm.ApplyDwmWindowAttributes;
const
  DwmImmersiveDarkModeAttribute = 20;
  DwmBorderColorAttribute = 35;
var
  BorderColor: COLORREF;
  DarkMode: BOOL;
  CornerPreference: Integer;
  NcRenderingPolicy: Integer;
  TransitionsForcedDisabled: BOOL;
begin
  if not HandleAllocated then
    Exit;

  // Published Windows11 DWM attributes; older Windows safely ignores them.
  BorderColor := $FFFFFFFE; // DWMWA_COLOR_NONE
  DwmSetWindowAttribute(Handle, DwmBorderColorAttribute, @BorderColor, SizeOf(BorderColor));
  DarkMode := True;
  DwmSetWindowAttribute(Handle, DwmImmersiveDarkModeAttribute, @DarkMode, SizeOf(DarkMode));

  NcRenderingPolicy := DWMNCRP_ENABLED;
  DwmSetWindowAttribute(Handle, DWMWA_NCRENDERING_POLICY,
    @NcRenderingPolicy, SizeOf(NcRenderingPolicy));
  TransitionsForcedDisabled := False;
  DwmSetWindowAttribute(Handle, DWMWA_TRANSITIONS_FORCEDISABLED,
    @TransitionsForcedDisabled, SizeOf(TransitionsForcedDisabled));
  CornerPreference := DWMWCP_ROUND;
  DwmSetWindowAttribute(Handle, DWMWA_WINDOW_CORNER_PREFERENCE,
    @CornerPreference, SizeOf(CornerPreference));
  SetWindowPos(Handle, 0, 0, 0, 0, 0,
    SWP_NOMOVE or SWP_NOSIZE or SWP_NOZORDER or SWP_NOACTIVATE or
    SWP_FRAMECHANGED);
end;

procedure TMainForm.LoadApplicationIcon;
var
  ResourceIcon: HICON;
  Size: Integer;
begin
  Size := ScaleValue(32);
  ResourceIcon := HICON(LoadImage(HInstance,PChar(AppIconResourceName),IMAGE_ICON,
    Size,Size,LR_DEFAULTCOLOR));
  if ResourceIcon<>0 then
  begin
    Icon.Handle := ResourceIcon;
    Application.Icon.Assign(Icon);
    if HandleAllocated then SendMessage(Handle,WM_SETICON,ICON_BIG,LPARAM(Icon.Handle));
  end;
  Size := ScaleValue(16);
  ResourceIcon := HICON(LoadImage(HInstance,PChar(AppIconResourceName),IMAGE_ICON,
    Size,Size,LR_DEFAULTCOLOR));
  if ResourceIcon<>0 then
  begin
    if FSmallWindowIcon=nil then FSmallWindowIcon:=TIcon.Create;
    FSmallWindowIcon.Handle:=ResourceIcon;
    if HandleAllocated then SendMessage(Handle,WM_SETICON,ICON_SMALL,LPARAM(FSmallWindowIcon.Handle));
  end;
  if FTitleIcon<>nil then FTitleIcon.Invalidate;
end;

procedure TMainForm.InitializeTaskbarList;
var
  Taskbar: ITaskbarList3;
begin
  if FTaskbarList <> nil then
    Exit;

  if Succeeded(CoCreateInstance(CLSID_TaskbarList, nil, CLSCTX_INPROC_SERVER,
    ITaskbarList3, Taskbar)) and Succeeded(Taskbar.HrInit) then
    FTaskbarList := Taskbar;
end;

procedure TMainForm.InitializeShellIntegration;
begin
  if not HandleAllocated then
    HandleNeeded;
  InitializeTaskbarList;
  SetTaskbarProgress(FProgressPercent, FProgressError);
end;

procedure TMainForm.ClearTaskbarProgress;
begin
  if not HandleAllocated then
    Exit;
  InitializeTaskbarList;
  if FTaskbarList <> nil then
    FTaskbarList.SetProgressState(Handle, TBPF_NOPROGRESS);
end;

procedure TMainForm.SetTaskbarProgress(const Percent: Integer; const IsError: Boolean);
var
  NormalizedPercent: UInt64;
begin
  if not HandleAllocated then
    Exit;
  InitializeTaskbarList;
  if FTaskbarList = nil then
    Exit;

  NormalizedPercent := UInt64(Max(0, Min(100, Percent)));
  if IsError and ((FTask <> nil) or BenchmarkBusy) then
  begin
    FTaskbarList.SetProgressState(Handle, TBPF_ERROR);
    FTaskbarList.SetProgressValue(Handle, NormalizedPercent, 100);
  end
  else if FTask <> nil then
  begin
    FTaskbarList.SetProgressState(Handle, TBPF_NORMAL);
    FTaskbarList.SetProgressValue(Handle, NormalizedPercent, 100);
  end
  else if BenchmarkBusy then
  begin
    if FBenchLast.CompletedPasses=0 then
      FTaskbarList.SetProgressState(Handle,TBPF_INDETERMINATE)
    else
    begin
      FTaskbarList.SetProgressState(Handle,TBPF_NORMAL);
      FTaskbarList.SetProgressValue(Handle,NormalizedPercent,100);
    end;
  end
  else FTaskbarList.SetProgressState(Handle, TBPF_NOPROGRESS);
end;

procedure TMainForm.MinimizeToTaskbar;
begin
  if HandleAllocated then
    SendMessage(Handle, WM_SYSCOMMAND, SC_MINIMIZE, 0);
end;

procedure TMainForm.WndProc(var Message: TMessage);
begin
  if (FTaskbarButtonCreatedMessage <> 0) and
    (Message.Msg = FTaskbarButtonCreatedMessage) then
  begin
    FTaskbarList := nil;
    InitializeTaskbarList;
    SetTaskbarProgress(FProgressPercent, FProgressError);
    inherited WndProc(Message);
    Exit;
  end;
  inherited WndProc(Message);
  if Message.Msg=WM_DPICHANGED then
  begin
    LoadApplicationIcon;
    ConstrainToWorkArea;
    LayoutMainPanels;
  end
  else if (Message.Msg=WM_SETTINGCHANGE) or (Message.Msg=WM_DISPLAYCHANGE) then
    ConstrainToWorkArea;
end;

procedure TMainForm.ConstrainToWorkArea;
var Info: TMonitorInfo;
    W,H,X,Y: Integer;
begin
  if not HandleAllocated then Exit;
  Info.cbSize:=SizeOf(Info);
  if not GetMonitorInfo(MonitorFromWindow(Handle,MONITOR_DEFAULTTONEAREST),@Info) then Exit;
  Constraints.MinWidth := Min(ScaleValue(UiMinimumWidth), Info.rcWork.Width);
  Constraints.MinHeight := Min(ScaleValue(UiMinimumHeight), Info.rcWork.Height);
  if WindowState<>wsNormal then Exit;
  W:=Min(Width,Info.rcWork.Right-Info.rcWork.Left);
  H:=Min(Height,Info.rcWork.Bottom-Info.rcWork.Top);
  X:=EnsureRange(Left,Info.rcWork.Left,Info.rcWork.Right-W);
  Y:=EnsureRange(Top,Info.rcWork.Top,Info.rcWork.Bottom-H);
  if (X<>Left) or (Y<>Top) or (W<>Width) or (H<>Height) then SetBounds(X,Y,W,H);
end;

procedure TMainForm.WMNCActivate(var Message: TMessage);
begin
  Message.Result := 1;
end;

procedure TMainForm.WMNCCalcSize(var Message: TWMNCCalcSize);
var
  MonitorInfo: TMonitorInfo;
begin
  if not Message.CalcValidRects then
  begin
    Message.Result := 0;
    Exit;
  end;

  if Message.CalcSize_Params <> nil then
  begin
    if WindowState = wsMaximized then
    begin
      MonitorInfo.cbSize := SizeOf(MonitorInfo);
      if GetMonitorInfo(MonitorFromWindow(Handle, MONITOR_DEFAULTTONEAREST), @MonitorInfo) then
        Message.CalcSize_Params.rgrc[0] := MonitorInfo.rcWork;
    end;
    Message.Result := 0;
    Exit;
  end;
  inherited;
end;

procedure TMainForm.WMNCPaint(var Message: TMessage);
begin
  Message.Result := 0;
end;

procedure TMainForm.ScaleForPPI(NewPPI: Integer);
begin
  inherited;
  LayoutMainPanels;
end;

procedure TMainForm.Resize;
var
  Kind: TWindowButtonKind;
begin
  inherited;
  if FLanguagePopup <> nil then
    FLanguagePopup.Hide;
  if not HandleAllocated then
    Exit;
  if FResizeGrip<>nil then
    FResizeGrip.Visible := WindowState=wsNormal;
  LayoutMainPanels;
  for Kind := Low(TWindowButtonKind) to High(TWindowButtonKind) do
    if FWindowButtons[Kind] <> nil then
      FWindowButtons[Kind].Invalidate;
end;

function TMainForm.CaptionWidth(const Text: string; const TextFont: TFont): Integer;
begin
  Canvas.Font.Assign(TextFont);
  Result := Canvas.TextWidth(Text);
end;

procedure TMainForm.LayoutTitleBar(Sender: TObject);
var RightEdge, BarHeight, ButtonWidth: Integer;
    Kind: TWindowButtonKind;
begin
  if (FLanguageButton=nil) or (FAboutButton=nil) or (FWindowButtons[wbClose]=nil) then Exit;
  RightEdge := FLanguageButton.Parent.ClientWidth;
  BarHeight := FLanguageButton.Parent.ClientHeight;
  ButtonWidth := ScaleValue(46);
  for Kind := High(TWindowButtonKind) downto Low(TWindowButtonKind) do
  begin
    Dec(RightEdge, ButtonWidth);
    FWindowButtons[Kind].SetBounds(RightEdge, 0, ButtonWidth, BarHeight);
  end;
  ButtonWidth := Max(ScaleValue(72), CaptionWidth(FAboutButton.Caption, FAboutButton.Font)+ScaleValue(24));
  Dec(RightEdge, ButtonWidth);
  FAboutButton.SetBounds(RightEdge, 0, ButtonWidth, BarHeight);
  ButtonWidth := Max(ScaleValue(64), CaptionWidth(FLanguageButton.Caption, FLanguageButton.Font)+ScaleValue(40));
  Dec(RightEdge, ButtonWidth);
  FLanguageButton.SetBounds(RightEdge, 0, ButtonWidth, BarHeight);
  FTitleLabel.Width := Max(0, RightEdge - ScaleValue(12) - FTitleLabel.Left);
end;

procedure TMainForm.LayoutMainPanels;
const
  PathHeight = UiFieldTop + UiOptionHeight;
  OutputTop = UiModeTop + PathHeight + 12;
  SettingsTop = OutputTop + PathHeight + 20;
  OptionRowTop = PathHeight + UiGap;
var
  PanelWidth, ViewportHeight, SettingsHeight, Gap, FieldHeight, LabelHeight, FieldTop: Integer;
  GroupWidth, ColumnWidth, DictionaryLeft, ThreadsLeft, OptionTop, CheckTop: Integer;
  ContainerMinWidth, CheckMinWidth: Integer;
  ActionLeft, ActionTop, ActionWidth, StatusWidth, I, X, W, ModeMinWidth: Integer;
  Compression, CustomDictionary, StackedCheck: Boolean;
  ModeButtons: array[0..2] of TPanel;
  ModeWidths: array[0..2] of Integer;

  procedure PlaceLabel(const LabelControl: TLabel; const X, Y, AWidth: Integer);
  begin
    LabelControl.SetBounds(X, Y, AWidth, LabelHeight);
  end;

  procedure LayoutPathRow(const Row, Shell, BrowseButton: TPanel;
    const Edit: TEdit; const LabelControl: TLabel; const Top: Integer);
  var BrowseWidth, EditHeight, Inset: Integer;
  begin
    BrowseWidth := Max(ScaleValue(100), CaptionWidth(BrowseButton.Caption,BrowseButton.Font)+ScaleValue(24));
    Inset := ScaleValue(12);
    Row.SetBounds(0, Top, PanelWidth, FieldTop+FieldHeight);
    PlaceLabel(LabelControl, 0, 0, PanelWidth);
    Shell.SetBounds(0, FieldTop, PanelWidth-BrowseWidth-ScaleValue(12), FieldHeight);
    BrowseButton.SetBounds(PanelWidth-BrowseWidth, FieldTop, BrowseWidth, FieldHeight);
    Edit.AutoSize := False;
    EditHeight := GuiNativeEditHeight(Edit.Font);
    Edit.SetBounds(Inset, (Shell.ClientHeight-EditHeight+1) div 2,
      Shell.ClientWidth-2*Inset, EditHeight);
  end;

  function SegmentMinimum(const Buttons: array of TPanel): Integer;
  var TextWidth: Integer;
  begin
    TextWidth := 0;
    for var Button in Buttons do
      TextWidth := Max(TextWidth, CaptionWidth(Button.Caption,Button.Font));
    Result := 2*ScaleValue(2)+Length(Buttons)*(TextWidth+ScaleValue(12));
  end;

  procedure LayoutSegments(const Group: TPanel; const Buttons: array of TPanel);
  var J, Inset, InnerWidth, LeftEdge, RightEdge: Integer;
  begin
    Inset := ScaleValue(2);
    InnerWidth := Group.ClientWidth - 2*Inset;
    for J := Low(Buttons) to High(Buttons) do
    begin
      LeftEdge := Inset + MulDiv(J, InnerWidth, Length(Buttons));
      RightEdge := Inset + MulDiv(J+1, InnerWidth, Length(Buttons));
      Buttons[J].SetBounds(LeftEdge, Inset, RightEdge-LeftEdge, Group.ClientHeight-2*Inset);
    end;
  end;

begin
  if FLayoutActive then Exit;
  if (FMainPanel=nil) or (FBenchCopy=nil) or (FMainPanel.ClientWidth<=0) then Exit;
  FLayoutActive := True;
  try
    ApplyLogicalFontHeights(FLogicalFonts, PixelsPerInch);
    LayoutTitleBar(nil);
    FMainPanel.Parent.Padding.Bottom := ScaleValue(UiBottomPadding) -
      Ord(FResizeGrip.Visible)*FResizeGrip.Height;
    ViewportHeight := FMainPanel.Parent.ClientHeight -
      FMainPanel.Parent.Padding.Top - FMainPanel.Parent.Padding.Bottom;
    Compression := FModeIndex=0;
    CustomDictionary := Compression and FDictionaryCustomShell.Visible;
    Gap := ScaleValue(UiGap);
    ContainerMinWidth := SegmentMinimum(FContainerButtons);
    CheckMinWidth := SegmentMinimum(FCheckButtons);
    StackedCheck := FCheckGroup.Visible and
      (ContainerMinWidth+Gap+CheckMinWidth>FMainPanel.ClientWidth);
    SettingsHeight := PathHeight;
    if Compression then Inc(SettingsHeight, OptionRowTop);
    if CustomDictionary then Inc(SettingsHeight, UiOptionHeight+8);
    if StackedCheck then Inc(SettingsHeight, OptionRowTop);
    if FModeIndex=2 then
      FMainPanel.Height := Max(ViewportHeight,ScaleValue(UiModeTop+UiBenchmarkHeight))
    else
      FMainPanel.Height := Max(ViewportHeight,ScaleValue(SettingsTop+SettingsHeight+UiGap+UiActivityHeight));

    PanelWidth := FMainPanel.ClientWidth;
    // A custom dictionary can add the vertical scrollbar at this width.
    if FCheckGroup.Visible and not StackedCheck and
      (ContainerMinWidth+Gap+CheckMinWidth>PanelWidth) then
    begin
      StackedCheck := True;
      Inc(SettingsHeight, OptionRowTop);
      FMainPanel.Height := Max(ViewportHeight,ScaleValue(SettingsTop+SettingsHeight+UiGap+UiActivityHeight));
      PanelWidth := FMainPanel.ClientWidth;
    end;
    FieldHeight := ScaleValue(UiOptionHeight);
    LabelHeight := ScaleValue(UiLabelHeight);
    FieldTop := ScaleValue(UiFieldTop);
    FFilesPanel.SetBounds(0, 0, PanelWidth, FMainPanel.ClientHeight);

    ModeButtons[0] := FCompressModeButton;
    ModeButtons[1] := FDecompressModeButton;
    ModeButtons[2] := FBenchmarkModeButton;
    ModeMinWidth := Min(ScaleValue(108), (PanelWidth-ScaleValue(8)) div 3);
    W := ScaleValue(8);
    for I := Low(ModeButtons) to High(ModeButtons) do
    begin
      ModeWidths[I] := Max(ModeMinWidth, CaptionWidth(ModeButtons[I].Caption, ModeButtons[I].Font)+ScaleValue(24));
      Inc(W, ModeWidths[I]);
    end;
    if W>PanelWidth then
    begin
      for I := Low(ModeButtons) to High(ModeButtons) do
        ModeWidths[I] := MulDiv(ModeWidths[I], PanelWidth-ScaleValue(8), W-ScaleValue(8));
      W := PanelWidth;
    end;
    FModePanel.SetBounds(0, 0, W, FieldHeight);
    X := ScaleValue(2);
    for I := Low(ModeButtons) to High(ModeButtons) do
    begin
      ModeButtons[I].SetBounds(X, ScaleValue(2), ModeWidths[I], FieldHeight-ScaleValue(4));
      Inc(X, ModeWidths[I]+ScaleValue(2));
    end;

    if FModeIndex=2 then
    begin
      LayoutBenchmark;
      Exit;
    end;

    LayoutPathRow(FInputRow, FInputShell, FInputBrowseButton, FInputEdit, FInputLabel, ScaleValue(UiModeTop));
    LayoutPathRow(FOutputRow, FOutputShell, FOutputBrowseButton, FOutputEdit, FOutputLabel, ScaleValue(OutputTop));
    FSettingsPanel.SetBounds(0, ScaleValue(SettingsTop), PanelWidth, ScaleValue(SettingsHeight));
    GroupWidth := (PanelWidth-Gap) div 2;
    if StackedCheck then GroupWidth := PanelWidth
    else if FCheckGroup.Visible then
      GroupWidth := EnsureRange(GroupWidth,ContainerMinWidth,PanelWidth-Gap-CheckMinWidth);
    PlaceLabel(FContainerLabel, 0, 0, GroupWidth);
    FContainerGroup.SetBounds(0, FieldTop, GroupWidth, FieldHeight);
    LayoutSegments(FContainerGroup, FContainerButtons);
    if FCheckGroup.Visible then
    begin
      if StackedCheck then
      begin
        X := 0;
        CheckTop := ScaleValue(OptionRowTop);
      end
      else
      begin
        X := GroupWidth+Gap;
        CheckTop := 0;
      end;
      PlaceLabel(FCheckLabel, X, CheckTop, PanelWidth-X);
      FCheckGroup.SetBounds(X, CheckTop+FieldTop, PanelWidth-X, FieldHeight);
      LayoutSegments(FCheckGroup, FCheckButtons);
    end;

    if Compression then
    begin
      ColumnWidth := (PanelWidth-Gap*2) div 3;
      DictionaryLeft := ColumnWidth+Gap;
      ThreadsLeft := PanelWidth-ColumnWidth;
      OptionTop := ScaleValue(OptionRowTop);
      if StackedCheck then Inc(OptionTop, ScaleValue(OptionRowTop));
      PlaceLabel(FLevelLabel, 0, OptionTop, ColumnWidth);
      PlaceLabel(FDictionaryLabel, DictionaryLeft, OptionTop, ColumnWidth);
      FLevelCombo.SetBounds(0, OptionTop+FieldTop, ColumnWidth, FieldHeight);
      FDictionaryCombo.SetBounds(DictionaryLeft, OptionTop+FieldTop, ColumnWidth, FieldHeight);
      if CustomDictionary then
      begin
        FDictionaryCustomShell.SetBounds(DictionaryLeft,
          OptionTop+FieldTop+FieldHeight+ScaleValue(8), ColumnWidth, FieldHeight);
        FDictionaryCustomEdit.AutoSize := False;
        W := GuiNativeEditHeight(FDictionaryCustomEdit.Font);
        FDictionaryCustomEdit.SetBounds(ScaleValue(12), (FieldHeight-W+1) div 2,
          ColumnWidth-ScaleValue(24), W);
      end;
    end
    else
    begin
      OptionTop := 0;
      ColumnWidth := PanelWidth-GroupWidth-Gap;
      ThreadsLeft := GroupWidth+Gap;
    end;
    PlaceLabel(FThreadsLabel, ThreadsLeft, OptionTop, ColumnWidth);
    FThreadsCombo.SetBounds(ThreadsLeft, OptionTop+FieldTop, ColumnWidth, FieldHeight);

    FActivityPanel.SetBounds(0, FMainPanel.ClientHeight-ScaleValue(UiActivityHeight),
      PanelWidth, ScaleValue(UiActivityHeight));
    ActionWidth := Max(ScaleValue(160), Max(CaptionWidth(FStartButton.Caption,FStartButton.Font),
      CaptionWidth(FCancelButton.Caption,FCancelButton.Font))+ScaleValue(32));
    ActionLeft := PanelWidth-ActionWidth;
    ActionTop := FActivityPanel.ClientHeight-FieldHeight-ScaleValue(UiActionInset);
    StatusWidth := Max(0, ActionLeft-Gap);
    FStartButton.SetBounds(ActionLeft, ActionTop, ActionWidth, FieldHeight);
    FCancelButton.SetBounds(ActionLeft, ActionTop, ActionWidth, FieldHeight);
    FProgressTrack.SetBounds(0, ScaleValue(28), StatusWidth, ScaleValue(4));
    FProgressLabel.SetBounds(Max(0, StatusWidth-ScaleValue(48)), 0, ScaleValue(48), LabelHeight);
    if FStatusLabel.Visible and FStatsLabel.Visible then
    begin
      W := StatusWidth;
      if FTask<>nil then W := Max(0, FProgressLabel.Left-ScaleValue(8));
      FStatusLabel.SetBounds(0, 0, W, ScaleValue(24));
      FStatsLabel.SetBounds(0, ScaleValue(36), StatusWidth, ScaleValue(UiActivityHeight-36));
    end
    else
    begin
      FStatusLabel.SetBounds(0, ScaleValue(4), StatusWidth, ScaleValue(52));
      FStatsLabel.SetBounds(0, ScaleValue(4), StatusWidth, ScaleValue(52));
    end;
    FReadyLabel.SetBounds(0, ActionTop, StatusWidth, FieldHeight);
    SetProgressVisual(FProgressPercent, FProgressError);
  finally
    FLayoutActive := False;
  end;
end;

procedure TMainForm.MainPanelResize(Sender: TObject);
begin
  LayoutMainPanels;
end;

function TMainForm.TextOf(const Key: string): string;
begin
  Result:=GuiText(Ord(FLanguage),Key);
end;

function TMainForm.DictionaryCaption(const ValueMb: Integer): string;
begin
  Result:=Format('%d %s',[ValueMb,TextOf('MB')]);
end;

function GuiFormatBytes(const Value: UInt64; const Language: TGuiLanguage): string;
var Scaled: Double; UnitIndex: Integer;
begin
  Scaled:=Value;UnitIndex:=0;
  while (Scaled>=1024) and (UnitIndex<3) do begin Scaled:=Scaled/1024;Inc(UnitIndex);end;
  if UnitIndex=0 then Result:=Format('%d %s',[Value,GuiByteUnit(Ord(Language),UnitIndex)],GuiNumberFormat(Ord(Language)))
  else Result:=Format('%.1f %s',[Scaled,GuiByteUnit(Ord(Language),UnitIndex)],GuiNumberFormat(Ord(Language)));
end;

function GuiFormatRate(const BytesPerSecond: Double; const Language: TGuiLanguage): string;
begin
  Result:=Format('%.2f %s/s',[BytesPerSecond/1048576.0,GuiByteUnit(Ord(Language),2)],GuiNumberFormat(Ord(Language)));
end;

function ArchiveStoredPathFromFullPath(const BaseParent, FullPath: string): string;
var
  Base: string;
  Full: string;
begin
  Base := IncludeTrailingPathDelimiter(ExpandFileName(BaseParent));
  Full := ExpandFileName(FullPath);
  Result := ExtractRelativePath(Base, Full);
  if Result = '' then
    Result := ExtractFileName(ExcludeTrailingPathDelimiter(Full));
  Result := StringReplace(Result, '\', '/', [rfReplaceAll]);
end;

procedure AddSevenZipGuiEntry(var Entries: TArray<TLzma7zEncodeEntry>;
  var SourcePaths: TArray<string>; const StoredName, SourcePath: string;
  const IsDirectory: Boolean; var TotalInputBytes: UInt64);
var
  FileSize: Int64;
  OldLen: Integer;
begin
  OldLen := Length(Entries);
  SetLength(Entries, OldLen + 1);
  SetLength(SourcePaths, OldLen + 1);
  Entries[OldLen].FileName := StoredName;
  Entries[OldLen].IsDirectory := IsDirectory;
  Entries[OldLen].HasAttributes := True;
  if IsDirectory then
    Entries[OldLen].Attributes := $10
  else
    Entries[OldLen].Attributes := $20;
  SourcePaths[OldLen] := SourcePath;
  if not IsDirectory then
  begin
    FileSize := TFile.GetSize(SourcePath);
    if FileSize > 0 then
      Inc(TotalInputBytes, UInt64(FileSize));
  end;
end;

procedure TMainForm.CollectSevenZipSourceEntries(const SourcePath: string;
  out Entries: TArray<TLzma7zEncodeEntry>; out SourcePaths: TArray<string>;
  out TotalInputBytes: UInt64);
var
  BaseParent: string;
  Dirs: TStringDynArray;
  Files: TStringDynArray;
  FullInput: string;
  Path: string;
begin
  SetLength(Entries, 0);
  SetLength(SourcePaths, 0);
  TotalInputBytes := 0;
  FullInput := ExpandFileName(SourcePath);
  if TDirectory.Exists(FullInput) then
  begin
    FullInput := ExcludeTrailingPathDelimiter(FullInput);
    BaseParent := ExtractFileDir(FullInput);
    AddSevenZipGuiEntry(Entries, SourcePaths,
      ArchiveStoredPathFromFullPath(BaseParent, FullInput), FullInput, True, TotalInputBytes);

    Dirs := TDirectory.GetDirectories(FullInput, '*', TSearchOption.soAllDirectories);
    TArray.Sort<string>(Dirs);
    for Path in Dirs do
      AddSevenZipGuiEntry(Entries, SourcePaths,
        ArchiveStoredPathFromFullPath(BaseParent, Path), Path, True, TotalInputBytes);

    Files := TDirectory.GetFiles(FullInput, '*', TSearchOption.soAllDirectories);
    TArray.Sort<string>(Files);
    for Path in Files do
      AddSevenZipGuiEntry(Entries, SourcePaths,
        ArchiveStoredPathFromFullPath(BaseParent, Path), Path, False, TotalInputBytes);
  end
  else if TFile.Exists(FullInput) then
    AddSevenZipGuiEntry(Entries, SourcePaths, ExtractFileName(FullInput), FullInput,
      False, TotalInputBytes)
  else
    raise EArgumentException.Create(TextOf('Source path was not found.'));
  if Length(Entries) = 0 then
    raise EArgumentException.Create(TextOf('The source folder has no files to archive.'));
end;

procedure TMainForm.UpdateDefaultOutputPath(const Force: Boolean);
var
  BaseName: string;
  DirectoryName: string;
  Extension: string;
  InputPath: string;
  OutputPath: string;
  SourceExtension: string;
begin
  if FOutputEdit = nil then
    Exit;
  if (not Force) and (not FOutputAutoGenerated) and (Trim(FOutputEdit.Text) <> '') then
    Exit;

  InputPath := Trim(FInputEdit.Text);
  if InputPath = '' then
    Exit;

  if TDirectory.Exists(InputPath) then
  begin
    InputPath := ExcludeTrailingPathDelimiter(InputPath);
    DirectoryName := ExtractFileDir(InputPath);
    BaseName := ExtractFileName(InputPath);
  end
  else
  begin
    DirectoryName := ExtractFileDir(InputPath);
    BaseName := ChangeFileExt(ExtractFileName(InputPath), '');
  end;

  if FLastOutputDirectory <> '' then
    DirectoryName := FLastOutputDirectory;
  if DirectoryName = '' then
    DirectoryName := GetCurrentDir;

  if FModeIndex = 0 then
  begin
    case FContainerIndex of
      0: Extension := '.lzma';
      1: Extension := '.lzma2';
      3: Extension := '.7z';
    else
      Extension := '.xz';
    end;
    if BaseName = '' then
      BaseName := 'archive';
    OutputPath := IncludeTrailingPathDelimiter(DirectoryName) + BaseName + Extension;
  end
  else
  begin
    SourceExtension := LowerCase(ExtractFileExt(InputPath));
    if (SourceExtension = '.xz') or (SourceExtension = '.lzma') or
      (SourceExtension = '.lzma2') or (SourceExtension = '.7z') then
      BaseName := ChangeFileExt(ExtractFileName(InputPath), '')
    else
      BaseName := ExtractFileName(InputPath) + '.out';
    if BaseName = '' then
      BaseName := 'output';
    OutputPath := IncludeTrailingPathDelimiter(DirectoryName) + BaseName;
  end;

  SetOutputPathText(OutputPath, True);
end;

procedure TMainForm.SetPanelButtonEnabled(const Button: TPanel; const Enabled,
  Primary: Boolean);
begin
  if Button = nil then
    Exit;
  Button.Enabled := Enabled;
  Button.ParentBackground := False;
  Button.BevelOuter := bvNone;
  if Button is TRoundedPanel then
  begin
    TRoundedPanel(Button).UseGradient := Enabled and Primary;
    TRoundedPanel(Button).GradientToColor := UiAccentHover;
    if Primary then
      TRoundedPanel(Button).HoverColor := UiAccentHover
    else
      TRoundedPanel(Button).HoverColor := UiBorder;
    TRoundedPanel(Button).BorderColor := UiBorder;
    TRoundedPanel(Button).BorderWidth := 1;
  end;
  if not Enabled then
  begin
    Button.Color := UiSurfaceHigh;
    Button.Font.Color := UiMutedText;
  end
  else if Primary then
  begin
    Button.Color := UiAccent;
    Button.Font.Color := UiAccentText;
  end
  else
  begin
    Button.Color := UiSurfaceAlt;
    Button.Font.Color := UiText;
  end;
  Button.Invalidate;
end;

procedure TMainForm.SetProgressVisual(const Percent: Integer; const IsError: Boolean);
var
  FillWidth: Integer;
begin
  FProgressPercent := Max(0, Min(100, Percent));
  FProgressError := IsError;
  SetTaskbarProgress(FProgressPercent, IsError);
  if (FProgressTrack = nil) or (FProgressFill = nil) then
    Exit;

  FProgressTrack.Visible := (FTask <> nil) or (FProgressPercent > 0) or IsError;
  if FProgressLabel <> nil then
  begin
    FProgressLabel.Caption := Format('%d%%', [FProgressPercent]);
    FProgressLabel.Visible := FTask <> nil;
  end;
  FillWidth := MulDiv(FProgressTrack.ClientWidth, FProgressPercent, 100);
  FProgressFill.SetBounds(0, 0, FillWidth, FProgressTrack.ClientHeight);
  FProgressFill.Visible := FProgressPercent > 0;
  if IsError then
    FProgressFill.Color := UiDanger
  else if FProgressPercent >= 100 then
    FProgressFill.Color := UiSuccess
  else
    FProgressFill.Color := UiAccent;
  FProgressFill.Invalidate;
end;

procedure TMainForm.ResetActivityState;
begin
  if FTask <> nil then
    Exit;
  FProgressPercent := 0;
  FProgressError := False;
  ClearTaskbarProgress;
  if FProgressTrack <> nil then
    FProgressTrack.Visible := False;
  if FProgressLabel <> nil then
    FProgressLabel.Visible := False;
  if FProgressFill <> nil then
  begin
    FProgressFill.Visible := False;
    FProgressFill.SetBounds(0, 0, 0, FProgressFill.Height);
  end;
  if FStatusLabel <> nil then
  begin
    FStatusLabel.Caption := '';
    FStatusLabel.Visible := False;
    FStatusLabel.Font.Color := UiSubtleText;
  end;
  if FStatsLabel <> nil then
  begin
    FStatsLabel.Caption := '';
    FStatsLabel.Visible := False;
  end;
  UpdateStartState;
end;

procedure TMainForm.SetInlineStatus(const StatusText: string; const IsError: Boolean;
  const DetailsText: string);
begin
  if FReadyLabel <> nil then
    FReadyLabel.Visible := False;
  if FStatusLabel <> nil then
  begin
    FStatusLabel.Caption := StatusText;
    FStatusLabel.Hint := StatusText;
    FStatusLabel.Visible := StatusText <> '';
    if IsError then
      FStatusLabel.Font.Color := UiDanger
    else
      FStatusLabel.Font.Color := UiText;
  end;
  if FStatsLabel <> nil then
  begin
    FStatsLabel.Caption := DetailsText;
    FStatsLabel.Hint := DetailsText;
    FStatsLabel.Visible := DetailsText <> '';
  end;
  if FProgressTrack <> nil then
    FProgressTrack.Visible := False;
  if FProgressFill <> nil then
    FProgressFill.Visible := False;
  if FProgressLabel <> nil then
    FProgressLabel.Visible := False;
  LayoutMainPanels;
end;

procedure TMainForm.SetOutputPathText(const Value: string; const AutoGenerated: Boolean);
begin
  if FOutputEdit = nil then
    Exit;
  FUpdatingOutputPath := True;
  try
    FOutputEdit.Text := Value;
    FOutputEdit.Hint := Value;
    FOutputAutoGenerated := AutoGenerated;
  finally
    FUpdatingOutputPath := False;
  end;
end;

procedure TMainForm.ModalKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
var Dialog:TForm;
begin
  Dialog:=TForm(Sender);
  if (Key=Ord('A')) and (Shift=[ssCtrl]) and (Dialog.ActiveControl is TCustomEdit) then
  begin
    TCustomEdit(Dialog.ActiveControl).SelectAll;
    Key:=0;
    Exit;
  end;
  if Key=VK_ESCAPE then begin TForm(Sender).ModalResult:=mrCancel;Key:=0;end;
end;

function TMainForm.NewModalDialog(const Caption:string;const W,H:Integer):TForm;
begin
  Application.CancelHint;
  Result:=TGuiModalForm.CreateNew(Self);
  Result.ScaleForPPI(96);Result.Font.PixelsPerInch:=96;
  Result.BorderStyle:=bsNone;Result.Position:=poOwnerFormCenter;
  Result.PopupMode:=pmExplicit;Result.PopupParent:=Self;
  Result.Caption:=Caption;Result.ClientWidth:=W;Result.ClientHeight:=H;
  Result.Color:=UiModalSurface;Result.StyleElements:=[];
  Result.OnPaint:=PaintModalSurface;Result.DoubleBuffered:=True;
  TGuiModalForm(Result).UseFont(Result.Font, UiBodyText);
  Result.Font.Color:=UiText;
  Result.KeyPreview:=True;Result.OnKeyDown:=ModalKeyDown;
end;

procedure TMainForm.PrepareModalDialog(const Dialog:TForm;const Corner:TWindowButton;
  const W,H:Integer);
var Dark:BOOL;
begin
  Dark:=True;DwmSetWindowAttribute(Dialog.Handle,20,@Dark,SizeOf(Dark));
  Dialog.ScaleForPPI(PixelsPerInch);
  Dialog.ClientWidth:=ScaleValue(W);Dialog.ClientHeight:=ScaleValue(H);
  Corner.SetBounds(Dialog.ClientWidth-ScaleValue(44),ScaleValue(12),ScaleValue(32),ScaleValue(32));
  TGuiModalForm(Dialog).UpdateRegion;
end;

procedure TMainForm.PaintModalSurface(Sender:TObject);
var Dialog:TForm;D2D:TDirect2DCanvas;Stroke,Radius:Single;
begin
  Dialog:=TForm(Sender);
  Stroke:=Max(1,Dialog.PixelsPerInch/96);
  Radius:=MulDiv(UiModalCornerRadius,Dialog.PixelsPerInch,96);
  if not TDirect2DCanvas.Supported then
  begin
    Dialog.Canvas.Brush.Color:=UiModalSurface;Dialog.Canvas.Pen.Color:=UiModalBorder;
    Dialog.Canvas.Pen.Width:=Round(Stroke);
    Dialog.Canvas.RoundRect(0,0,Dialog.ClientWidth,Dialog.ClientHeight,
      Round(Radius*2),Round(Radius*2));
    Exit;
  end;
  D2D:=TDirect2DCanvas.Create(Dialog.Canvas,Dialog.ClientRect);
  try
    D2D.BeginDraw;
    try
      D2D.RenderTarget.SetDpi(96,96);
      D2D.RenderTarget.Clear(D2D1ColorF(UiModalSurface));
      D2D.Pen.Color:=UiModalBorder;
      D2D.RenderTarget.DrawRoundedRectangle(D2D1RoundedRect(
        D2D1RectF(Stroke*0.5,Stroke*0.5,Dialog.ClientWidth-Stroke*0.5,
          Dialog.ClientHeight-Stroke*0.5),Radius,Radius),D2D.Pen.Brush.Handle,Stroke);
    finally D2D.EndDraw;end;
  finally D2D.Free;end;
end;

procedure TMainForm.OpenProjectPage(Sender: TObject);
begin
  ShellExecute(Handle,'open',PChar(GuiProjectUrl),nil,nil,SW_SHOWNORMAL);
end;

procedure TMainForm.AboutClick(Sender: TObject);
const
  DialogWidth = 432;
  DialogHeight = 224;
  Margin = 24;
  FooterTop = 164;
  FooterGap = 12;
  FooterWidth = (DialogWidth-2*Margin-FooterGap) div 2;
  HeaderTextLeft = 84;
  HeaderCloseGap = 12;
var Dialog: TForm;
    Mark: TApplicationMark;
    CloseButton, ProjectButton: TRoundedPanel;
    CloseCorner: TWindowButton;
    HeaderTextWidth:Integer;
  procedure AddLine(const Text: string; const X,Y,W,Size: Integer; const Strong: Boolean=False);
  var TextControl: TEdit;
  begin
    TextControl:=TEdit.Create(Dialog);TextControl.Parent:=Dialog;
    TextControl.BorderStyle:=bsNone;TextControl.Ctl3D:=False;
    TextControl.ReadOnly:=True;TextControl.AutoSelect:=False;
    TextControl.Color:=UiModalSurface;TextControl.StyleElements:=[];
    TGuiModalForm(Dialog).UseFont(TextControl.Font, Size, Strong);
    TextControl.Font.Color:=UiText;
    TextControl.AutoSize:=True;TextControl.SetBounds(X,Y,W,TextControl.Height);
    TextControl.Text:=Text;TextControl.TabStop:=True;
  end;
begin
  if (FTask<>nil) or BenchmarkBusy then Exit;
  Dialog:=NewModalDialog(TextOf('About'),DialogWidth,DialogHeight);
  try
    CloseCorner:=TWindowButton.Create(Dialog);CloseCorner.Parent:=Dialog;
    CloseCorner.SetBounds(DialogWidth-44,12,32,32);CloseCorner.Anchors:=[akTop,akRight];
    CloseCorner.Color:=UiModalSurface;CloseCorner.CornerRadius:=6;
    CloseCorner.Kind:=wbClose;CloseCorner.Caption:=TextOf('Close');
    CloseCorner.Hint:=CloseCorner.Caption;CloseCorner.ShowHint:=True;
    CloseCorner.OnClick:=ModalOkClick;
    Mark:=TApplicationMark.Create(Dialog);Mark.Parent:=Dialog;Mark.ParentColor:=False;Mark.Color:=UiModalSurface;Mark.SetBounds(Margin,28,44,44);
    // Selectable EDITs are opaque windows. Keep the entire header text box
    // clear of the corner button, including its lower-left hover/hit area.
    HeaderTextWidth:=CloseCorner.Left-HeaderCloseGap-HeaderTextLeft;
    AddLine(GuiProductName,HeaderTextLeft,28,HeaderTextWidth,UiDialogTitleText,True);
{$IFDEF WIN64}
    AddLine(GuiProductVersion+' · Win64',HeaderTextLeft,56,HeaderTextWidth,UiBodyText);
{$ELSE}
    AddLine(GuiProductVersion+' · Win32',HeaderTextLeft,56,HeaderTextWidth,UiBodyText);
{$ENDIF}
    AddLine(Format(GuiApplicationValue('description'),[GuiSdkTarget]),Margin,96,DialogWidth-2*Margin,UiBodyText);
    AddLine(TextOf('License: MIT'),Margin,120,DialogWidth-2*Margin,UiBodyText);
    CloseButton:=TRoundedPanel.Create(Dialog);CloseButton.Parent:=Dialog;
    CloseButton.SetBounds(Margin+FooterWidth+FooterGap,FooterTop,FooterWidth,UiOptionHeight);CloseButton.Caption:=TextOf('Close');
    CloseButton.Color:=UiAccent;CloseButton.Font.Color:=UiAccentText;
    TGuiModalForm(Dialog).UseFont(CloseButton.Font, UiBodyText, True);CloseButton.Alignment:=taCenter;
    CloseButton.BevelOuter:=bvNone;CloseButton.ParentBackground:=False;
    CloseButton.TabStop:=True;CloseButton.Cursor:=crHandPoint;CloseButton.OnClick:=ModalOkClick;
    SetPanelButtonEnabled(CloseButton,True,True);CloseButton.UseGradient:=False;
    CloseButton.BorderColor:=clNone;CloseButton.BorderWidth:=0;
    ProjectButton:=TRoundedPanel.Create(Dialog);ProjectButton.Parent:=Dialog;
    ProjectButton.SetBounds(Margin,FooterTop,FooterWidth,UiOptionHeight);ProjectButton.Caption:=TextOf('GitHub');
    ProjectButton.Hint:=GuiProjectUrl;ProjectButton.ShowHint:=True;
    ProjectButton.Color:=UiSurfaceHigh;ProjectButton.Font.Color:=UiText;
    TGuiModalForm(Dialog).UseFont(ProjectButton.Font, UiBodyText, True);ProjectButton.Alignment:=taCenter;
    ProjectButton.BevelOuter:=bvNone;ProjectButton.ParentBackground:=False;
    ProjectButton.TabStop:=True;ProjectButton.Cursor:=crHandPoint;ProjectButton.OnClick:=OpenProjectPage;
    SetPanelButtonEnabled(ProjectButton,True,False);
    ProjectButton.Color:=UiSurfaceHigh;
    ProjectButton.BorderColor:=UiBorder;ProjectButton.BorderWidth:=1;
    ProjectButton.TabOrder:=4;CloseButton.TabOrder:=5;
    PrepareModalDialog(Dialog,CloseCorner,DialogWidth,DialogHeight);
    Dialog.ActiveControl:=CloseButton;
    Dialog.ShowModal;
  finally Dialog.Free;end;
end;

procedure TMainForm.ShowErrorDialog(const MessageText:string;const DiagnosticDetails:string);
const Width=472;Margin=24;ContentWidth=Width-Margin*2;Gap=12;ButtonHeight=UiOptionHeight;
var Dialog:TForm;Corner:TWindowButton;Title,MessageLabel,DetailLabel:TLabel;
    DetailHost,CopyButton,OkButton:TRoundedPanel;DetailEdit:TEdit;
    Report:TDialogCopyReport;R:TRect;BodyHeight,NextTop,FooterTop,Height:Integer;
  function FooterButton(const X:Integer;const Caption:string;const Primary:Boolean):TRoundedPanel;
  begin
    Result:=TRoundedPanel.Create(Dialog);Result.Parent:=Dialog;
    Result.SetBounds(X,FooterTop,(ContentWidth-Gap) div 2,ButtonHeight);
    Result.Caption:=Caption;
    TGuiModalForm(Dialog).UseFont(Result.Font, UiBodyText, True);
    Result.Alignment:=taCenter;Result.TabStop:=True;Result.Cursor:=crHandPoint;
    Result.BevelOuter:=bvNone;Result.ParentBackground:=False;
    SetPanelButtonEnabled(Result,True,Primary);Result.UseGradient:=False;
    if Primary then begin Result.BorderColor:=clNone;Result.BorderWidth:=0;end;
  end;
begin
  Dialog:=NewModalDialog(TextOf('Error'),Width,260);
  try
    Corner:=TWindowButton.Create(Dialog);Corner.Parent:=Dialog;
    Corner.SetBounds(Width-44,12,32,32);Corner.Anchors:=[akTop,akRight];
    Corner.Color:=UiModalSurface;Corner.CornerRadius:=6;Corner.Kind:=wbClose;
    Corner.Caption:=TextOf('Close');Corner.OnClick:=ModalOkClick;
    Title:=TLabel.Create(Dialog);Title.Parent:=Dialog;
    Title.SetBounds(Margin,24,Corner.Left-12-Margin,28);Title.AutoSize:=False;
    Title.Caption:=TextOf('Error');TGuiModalForm(Dialog).UseFont(Title.Font, UiDialogTitleText, True);
    Title.Font.Color:=UiText;Title.Transparent:=True;Title.OnMouseDown:=TitleBarMouseDown;
    Dialog.Canvas.Font.Assign(Dialog.Font);
    R:=Rect(0,0,ContentWidth,0);
    DrawText(Dialog.Canvas.Handle,PChar(MessageText),Length(MessageText),R,
      DT_CALCRECT or DT_WORDBREAK or DT_NOPREFIX or DT_EDITCONTROL);
    BodyHeight:=Max(Dialog.Canvas.TextHeight('Agjp'),R.Height);
    MessageLabel:=TLabel.Create(Dialog);MessageLabel.Parent:=Dialog;
    MessageLabel.AutoSize:=False;MessageLabel.WordWrap:=True;
    MessageLabel.SetBounds(Margin,64,ContentWidth,BodyHeight);
    MessageLabel.Caption:=MessageText;MessageLabel.Font.Assign(Dialog.Font);
    MessageLabel.Transparent:=True;
    NextTop:=MessageLabel.Top+MessageLabel.Height+16;
    if DiagnosticDetails<>'' then
    begin
      DetailLabel:=TLabel.Create(Dialog);DetailLabel.Parent:=Dialog;
      DetailLabel.Caption:=TextOf('Details');DetailLabel.Font.Color:=UiMutedText;
      DetailLabel.SetBounds(Margin,NextTop,ContentWidth,UiLabelHeight);DetailLabel.Transparent:=True;
      Inc(NextTop,UiFieldTop);
      DetailHost:=TRoundedPanel.Create(Dialog);DetailHost.Parent:=Dialog;
      DetailHost.SetBounds(Margin,NextTop,ContentWidth,UiOptionHeight);DetailHost.Color:=UiInput;
      DetailHost.BevelOuter:=bvNone;DetailHost.ParentBackground:=False;
      DetailHost.CornerRadius:=6;DetailHost.BorderColor:=UiBorder;
      DetailEdit:=TEdit.Create(Dialog);DetailEdit.Parent:=DetailHost;
      DetailEdit.BorderStyle:=bsNone;DetailEdit.Ctl3D:=False;
      DetailEdit.StyleElements:=[];DetailEdit.ReadOnly:=True;DetailEdit.AutoSelect:=False;
      DetailEdit.Color:=UiInput;TGuiModalForm(Dialog).UseFont(DetailEdit.Font, UiBodyText);DetailEdit.Font.Color:=UiText;
      DetailEdit.AutoSize:=False;
      DetailEdit.Height:=GuiNativeEditHeight(DetailEdit.Font);
      DetailEdit.SetBounds(12,(UiOptionHeight-DetailEdit.Height+1) div 2,ContentWidth-24,DetailEdit.Height);
      DetailEdit.Text:=StringReplace(StringReplace(DiagnosticDetails,#13#10,'; ',[rfReplaceAll]),#10,'; ',[rfReplaceAll]);
      Inc(NextTop,UiOptionHeight+16);
    end;
    FooterTop:=NextTop;Height:=FooterTop+ButtonHeight+Margin;
    Dialog.ClientHeight:=Height;
    Report:=TDialogCopyReport.Create(Dialog);
    Report.Text:=GuiProductName+' '+GuiProductVersion+sLineBreak+MessageText;
    if DiagnosticDetails<>'' then Report.Text:=Report.Text+sLineBreak+DiagnosticDetails;
    CopyButton:=FooterButton(Margin,TextOf('Copy'),False);
    CopyButton.OnClick:=Report.CopyReport;
    OkButton:=FooterButton(Margin+(ContentWidth+Gap) div 2,TextOf('OK'),True);
    OkButton.OnClick:=ModalOkClick;
    PrepareModalDialog(Dialog,Corner,Width,Height);
    Dialog.ActiveControl:=OkButton;Dialog.ShowModal;
  finally Dialog.Free;end;
end;

procedure TMainForm.ReportException(const Error:Exception);
var Failure:TGuiFailure;
begin
  Failure:=DescribeGuiFailure(Error,Ord(FLanguage));
  SetInlineStatus(Failure.Summary,True);
  ShowErrorDialog(Failure.Summary,Failure.Details);
end;

procedure TMainForm.UpdateModeButtons;

  procedure ApplyModeButton(const Button: TPanel; const Selected: Boolean);
  begin
    if Button = nil then
      Exit;
    Button.ParentBackground := False;
    Button.BevelOuter := bvNone;
    if Button is TRoundedPanel then
    begin
      TRoundedPanel(Button).UseGradient := False;
      TRoundedPanel(Button).HoverColor := UiSurfaceAlt;
      TRoundedPanel(Button).GradientToColor := UiAccentHover;
      if Selected and Button.Enabled then
      begin
        TRoundedPanel(Button).BorderColor := UiSelectionBorder;
        TRoundedPanel(Button).BorderWidth := 1;
      end
      else
      begin
        TRoundedPanel(Button).BorderColor := clNone;
        TRoundedPanel(Button).BorderWidth := 0;
      end;
    end;
    if not Button.Enabled then
    begin
      if Selected then
      begin
        Button.Color := UiSurfaceAlt;
        Button.Font.Color := UiMutedText;
      end
      else
      begin
        Button.Color := UiInputDisabled;
        Button.Font.Color := UiSubtleText;
      end;
    end
    else if Selected then
    begin
      Button.Color := UiSelection;
      Button.Font.Color := UiAccentHover;
    end
    else
    begin
      Button.Color := UiInput;
      Button.Font.Color := UiMutedText;
    end;
    Button.Invalidate;
  end;

begin
  ApplyModeButton(FCompressModeButton, FModeIndex = 0);
  ApplyModeButton(FDecompressModeButton, FModeIndex = 1);
  ApplyModeButton(FBenchmarkModeButton, FModeIndex = 2);
  if FBenchmarkPanel <> nil then
  begin
    FBenchmarkPanel.Visible := FModeIndex = 2;
    FInputRow.Visible := FModeIndex <> 2;
    FOutputRow.Visible := FModeIndex <> 2;
    FSettingsPanel.Visible := FModeIndex <> 2;
    FActivityPanel.Visible := FModeIndex <> 2;
  end;
  if FStartButton <> nil then
  begin
    if FModeIndex = 0 then
      FStartButton.Caption := TextOf('Start compression')
    else
      FStartButton.Caption := TextOf('Start extraction');
    SetPanelButtonEnabled(FStartButton, FStartButton.Enabled, True);
  end;
end;

procedure TMainForm.UpdateOptionButtons;

  procedure ApplyOptionButton(const Button: TPanel; const Selected: Boolean);
  begin
    if Button = nil then
      Exit;
    Button.ParentBackground := False;
    Button.BevelOuter := bvNone;
    if Button is TRoundedPanel then
    begin
      TRoundedPanel(Button).UseGradient := False;
      TRoundedPanel(Button).HoverColor := UiSurfaceAlt;
      if Selected then
      begin
        if Button.Enabled then
          TRoundedPanel(Button).BorderColor := UiSelectionBorder
        else
          TRoundedPanel(Button).BorderColor := UiBorder;
      end
      else
        TRoundedPanel(Button).BorderColor := clNone;
      TRoundedPanel(Button).BorderWidth := Ord(Selected);
    end;
    if not Button.Enabled then
    begin
      if Selected then
      begin
        Button.Color := UiSurfaceAlt;
        Button.Font.Color := UiMutedText;
      end
      else
      begin
        Button.Color := UiInput;
        Button.Font.Color := UiSubtleText;
      end;
    end
    else if Selected then
    begin
      Button.Color := UiSelection;
      Button.Font.Color := UiAccentHover;
    end
    else
    begin
      Button.Color := UiInput;
      Button.Font.Color := UiMutedText;
    end;
    Button.Invalidate;
  end;

var
  CompressionMode, HasXzCheck, Idle: Boolean;
  I: Integer;
begin
  CompressionMode := FModeIndex = 0;
  HasXzCheck := CompressionMode and (FContainerIndex=2);
  Idle := FTask = nil;
  FCheckLabel.Visible := HasXzCheck;
  FCheckGroup.Visible := HasXzCheck;
  FLevelLabel.Visible := CompressionMode;
  FLevelCombo.Visible := CompressionMode;
  FDictionaryLabel.Visible := CompressionMode;
  FDictionaryCombo.Visible := CompressionMode;
  for I := Low(FContainerButtons) to High(FContainerButtons) do
  begin
    FContainerButtons[I].Enabled := Idle;
    ApplyOptionButton(FContainerButtons[I], FContainerIndex = I);
  end;
  FLevelCombo.Enabled := Idle and CompressionMode;
  FLevelCombo.ItemIndex := FLevelIndex;
  FLevelCombo.Invalidate;
  for I := Low(FCheckButtons) to High(FCheckButtons) do
  begin
    FCheckButtons[I].Enabled := Idle and HasXzCheck;
    ApplyOptionButton(FCheckButtons[I], FCheckIndex = I);
  end;
  FDictionaryCombo.Enabled := Idle and CompressionMode;
  FDictionaryCombo.ItemIndex := FDictionaryIndex;
  FDictionaryCombo.Invalidate;
  if FDictionaryCustomEdit <> nil then
  begin
    FDictionaryCustomShell.Visible := CompressionMode and (FDictionaryIndex=Length(DictionaryMbValues));
    FDictionaryCustomEdit.Enabled := FDictionaryCustomShell.Visible and
      Idle and CompressionMode;
  end;
  UpdateAutoThreads;
  LayoutMainPanels;
end;

procedure TMainForm.ContainerClick(Sender: TObject);
begin
  if (Sender is TPanel) and TPanel(Sender).Enabled then
  begin
    FContainerIndex := TPanel(Sender).Tag;
    ResetActivityState;
    UpdateDefaultOutputPath(False);
    UpdateOptionButtons;
  end;
end;

procedure TMainForm.LevelChange(Sender: TObject);
begin
  if FLevelCombo.Enabled and (FLevelCombo.ItemIndex >= 0) then
  begin
    FLevelIndex := FLevelCombo.ItemIndex;
    ResetActivityState;
    UpdateOptionButtons;
  end;
end;

procedure TMainForm.CheckClick(Sender: TObject);
begin
  if (Sender is TPanel) and TPanel(Sender).Enabled then
  begin
    FCheckIndex := TPanel(Sender).Tag;
    ResetActivityState;
    UpdateOptionButtons;
  end;
end;

procedure TMainForm.DictionaryChange(Sender: TObject);
begin
  if FDictionaryCombo.Enabled and (FDictionaryCombo.ItemIndex >= 0) then
  begin
    FDictionaryIndex := FDictionaryCombo.ItemIndex;
    ResetActivityState;
    UpdateOptionButtons;
    if (FDictionaryIndex = Length(DictionaryMbValues)) and (FDictionaryCustomEdit <> nil) and
      FDictionaryCustomEdit.Showing and FDictionaryCustomEdit.CanFocus then
    begin
      FDictionaryCustomEdit.SetFocus;
      FDictionaryCustomEdit.SelectAll;
    end;
  end;
end;

procedure TMainForm.DictionaryCustomEditChange(Sender: TObject);
begin
  if FDictionaryIndex <> Length(DictionaryMbValues) then
    FDictionaryIndex := Length(DictionaryMbValues);
  ResetActivityState;
  UpdateOptionButtons;
end;

procedure TMainForm.EditChange(Sender: TObject);
begin
  if Sender is TEdit then
    TEdit(Sender).Hint := TEdit(Sender).Text;
  if (Sender = FInputEdit) and (not FUpdatingOutputPath) then
    UpdateDefaultOutputPath(False)
  else if (Sender = FOutputEdit) and (not FUpdatingOutputPath) then
  begin
    FOutputAutoGenerated := False;
    if ExtractFileDir(Trim(FOutputEdit.Text)) <> '' then
      FLastOutputDirectory := ExtractFileDir(Trim(FOutputEdit.Text));
  end;
  ResetActivityState;
  UpdateStartState;
end;

procedure TMainForm.EditEnter(Sender: TObject);
begin
  if (Sender is TEdit) and (TEdit(Sender).Parent is TRoundedPanel) then
  begin
    TRoundedPanel(TEdit(Sender).Parent).BorderColor := UiAccent;
    TRoundedPanel(TEdit(Sender).Parent).BorderWidth := 1.5;
    TEdit(Sender).Parent.Invalidate;
  end;
end;

procedure TMainForm.EditExit(Sender: TObject);
begin
  if (Sender is TEdit) and (TEdit(Sender).Parent is TRoundedPanel) then
  begin
    TRoundedPanel(TEdit(Sender).Parent).BorderColor := UiBorder;
    TRoundedPanel(TEdit(Sender).Parent).BorderWidth := 1;
    TEdit(Sender).Parent.Invalidate;
  end;
end;

procedure TMainForm.UpdateStartState;
var
  Ready: Boolean;
begin
  if FStartButton = nil then
    Exit;

  Ready := (FTask = nil) and (Trim(FInputEdit.Text) <> '') and
    (Trim(FOutputEdit.Text) <> '') and
    ((FModeIndex<>0) or FThreadsCombo.InputValid);
  FStartButton.Visible := FTask = nil;
  if FCancelButton <> nil then
    FCancelButton.Visible := FTask <> nil;
  SetPanelButtonEnabled(FStartButton, Ready, True);
  if FReadyLabel <> nil then
  begin
    FReadyLabel.Visible := (FTask = nil) and Ready and not FStatusLabel.Visible and not FStatsLabel.Visible;
    if Trim(FInputEdit.Text) = '' then
      FReadyLabel.Caption := TextOf('Choose source path')
    else if Trim(FOutputEdit.Text) = '' then
      FReadyLabel.Caption := TextOf('Choose an output file.')
    else
      FReadyLabel.Caption := ExtractFileName(ExcludeTrailingPathDelimiter(Trim(FInputEdit.Text))) +
        '  →  ' + ExtractFileName(ExcludeTrailingPathDelimiter(Trim(FOutputEdit.Text)));
    FReadyLabel.Hint := FReadyLabel.Caption;
  end;
end;

procedure TMainForm.ThreadsChange(Sender: TObject);
begin
  ResetActivityState;
  UpdateAutoThreads;
  UpdateStartState;
end;

procedure TMainForm.UpdateAutoThreads;
var Options: TLzma2Options;
    N, Selected: Integer;
    Budget: UInt64;
    AutoCaption: string;
begin
  if FThreadsCombo = nil then Exit;
  Options := TLzma2.DefaultOptions;
  case FContainerIndex of
    0: Options.Container := lcLzma;
    1: Options.Container := lcRawLzma2;
    3: Options.Container := lc7z;
  else Options.Container := lcXz;
  end;
  Options.Level := TLzma2CompressionLevel(FLevelIndex);
  Budget:=GuiMemoryBudget;
  try Options.DictionarySize:=ResolvedDictionary(Budget);
  except Options.DictionarySize:=UInt64(1) shl 20;end;
  if (FDictionaryCombo<>nil) and (FDictionaryCombo.Items.Count>Length(DictionaryMbValues)+1) then
  begin
    Selected:=FDictionaryCombo.ItemIndex;
    FDictionaryCombo.Items[Length(DictionaryMbValues)+1]:=TextOf('Auto')+' ('+
      DictionaryCaption(Integer(GuiAutomaticDictionary(FLevelIndex,Max(1,FThreadsCombo.RequestedWorkers),Budget) shr 20))+')';
    FDictionaryCombo.ItemIndex:=Selected;
  end;
  N := AutoThreadCount(Options, Budget, GuiProcessorCount);
  AutoCaption := Format(TextOf('Auto (up to %d)'), [N]);
  FThreadsCombo.UpdateCaptions(AutoCaption,TextOf('Other...'),TextOf('Manual: %d'));
end;

procedure TMainForm.MinimizeWindowClick(Sender: TObject);
begin
  MinimizeToTaskbar;
end;

procedure TMainForm.MaximizeWindowClick(Sender: TObject);
begin
  if WindowState = wsMaximized then
    WindowState := wsNormal
  else
    WindowState := wsMaximized;
end;

procedure TMainForm.CloseWindowClick(Sender: TObject);
begin
  Close;
end;

procedure TMainForm.ModalOkClick(Sender: TObject);
var
  Form: TCustomForm;
begin
  if Sender is TControl then
  begin
    Form := GetParentForm(TControl(Sender));
    if Form <> nil then
      Form.ModalResult := mrOk;
  end;
end;

procedure TMainForm.ShowTitleSystemMenu(const ScreenPoint: TPoint);
var
  Command: UINT;
  Menu: HMENU;

begin
  Menu := GetSystemMenu(Handle, False);
  if Menu = 0 then
    Exit;

  EnableMenuItem(Menu, SC_RESTORE, MF_BYCOMMAND or IfThen(WindowState <> wsNormal,
    MF_ENABLED, MF_GRAYED));
  EnableMenuItem(Menu, SC_MOVE, MF_BYCOMMAND or IfThen(WindowState <> wsMaximized,
    MF_ENABLED, MF_GRAYED));
  EnableMenuItem(Menu, SC_SIZE, MF_BYCOMMAND or IfThen(WindowState <> wsMaximized,
    MF_ENABLED, MF_GRAYED));
  EnableMenuItem(Menu, SC_MINIMIZE, MF_BYCOMMAND or IfThen(WindowState <> wsMinimized,
    MF_ENABLED, MF_GRAYED));
  EnableMenuItem(Menu, SC_MAXIMIZE, MF_BYCOMMAND or IfThen(WindowState <> wsMaximized,
    MF_ENABLED, MF_GRAYED));
  EnableMenuItem(Menu, SC_CLOSE, MF_BYCOMMAND or MF_ENABLED);

  SetForegroundWindow(Handle);
  Command := TTrackPopupMenuResult(@TrackPopupMenu)(Menu,
    TPM_RETURNCMD or TPM_RIGHTBUTTON or TPM_LEFTALIGN or TPM_TOPALIGN,
    ScreenPoint.X, ScreenPoint.Y, 0, Handle, nil);
  if Command <> 0 then
    SendMessage(Handle, WM_SYSCOMMAND, Command, 0);
end;

procedure TMainForm.TitleBarContextPopup(Sender: TObject; MousePos: TPoint;
  var Handled: Boolean);
var
  TitleBar: TWinControl;
  MenuPoint: TPoint;
begin
  if (FLanguageButton = nil) or not (Sender is TControl) then
    Exit;
  TitleBar := FLanguageButton.Parent;
  if (MousePos.X < 0) or (MousePos.Y < 0) then
  begin
    if Sender = Self then
      Exit;
    MenuPoint := TitleBar.ClientToScreen(Point(ScaleValue(12), 0));
  end
  else
  begin
    MenuPoint := TControl(Sender).ClientToScreen(MousePos);
    if not PtInRect(TitleBar.ClientRect, TitleBar.ScreenToClient(MenuPoint)) then
      Exit;
  end;
  MenuPoint.Y := TitleBar.ClientToScreen(Point(0, TitleBar.ClientHeight)).Y;
  Handled := True;
  ShowTitleSystemMenu(MenuPoint);
end;

procedure TMainForm.TitleBarMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  DragHandle: HWND;
  Form: TCustomForm;
begin
  if Button = mbLeft then
  begin
    DragHandle := Handle;
    if Sender is TControl then
    begin
      Form := GetParentForm(TControl(Sender));
      if Form <> nil then
        DragHandle := Form.Handle;
    end;
    ReleaseCapture;
    SendMessage(DragHandle, WM_NCLBUTTONDOWN, HTCAPTION, 0);
  end;
end;

procedure TMainForm.TitleBarMouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  // Context menu is handled through OnContextPopup so the right-button release
  // cannot immediately dismiss the system menu.
end;

procedure TMainForm.WMNCHitTest(var Message: TWMNCHitTest);
var
  HitPoint: TPoint;
  ResizeGrip, ResizeCorner: Integer;
begin
  inherited;
  if WindowState = wsMaximized then
    Exit;
  ResizeGrip := ScaleValue(8);
  ResizeCorner := ScaleValue(UiResizeGripSize);
  HitPoint := ScreenToClient(Point(Message.XPos, Message.YPos));
  if (HitPoint.X >= ClientWidth - ResizeCorner) and
    (HitPoint.Y >= ClientHeight - ResizeCorner) then
    Message.Result := HTBOTTOMRIGHT
  else if (HitPoint.X < ResizeGrip) and (HitPoint.Y < ResizeGrip) then
    Message.Result := HTTOPLEFT
  else if (HitPoint.X > ClientWidth - ResizeGrip) and (HitPoint.Y < ResizeGrip) then
    Message.Result := HTTOPRIGHT
  else if (HitPoint.X < ResizeGrip) and (HitPoint.Y > ClientHeight - ResizeGrip) then
    Message.Result := HTBOTTOMLEFT
  else if HitPoint.X < ResizeGrip then
    Message.Result := HTLEFT
  else if HitPoint.X > ClientWidth - ResizeGrip then
    Message.Result := HTRIGHT
  else if HitPoint.Y < ResizeGrip then
    Message.Result := HTTOP
  else if HitPoint.Y > ClientHeight - ResizeGrip then
    Message.Result := HTBOTTOM;
end;

procedure TMainForm.ModeClick(Sender: TObject);
var PreviousFileMode: Integer;
begin
  if BenchmarkBusy then Exit;
  if (Sender is TPanel) and TPanel(Sender).Enabled then
  begin
    PreviousFileMode := FFileModeIndex;
    FModeIndex := TPanel(Sender).Tag;
    if FModeIndex <> 2 then
    begin
      FFileModeIndex := FModeIndex;
      if PreviousFileMode <> FModeIndex then
      begin
        ResetActivityState;
        UpdateDefaultOutputPath(False);
      end;
    end;
    UpdateModeButtons;
    UpdateOptionButtons;
    UpdateStartState;
    BenchmarkSettingsChanged(nil);
  end;
end;

procedure TMainForm.ProgressTrackResize(Sender: TObject);
begin
  SetProgressVisual(FProgressPercent, FProgressError);
end;

procedure TMainForm.SourceFolderChanging(Sender: TObject; var CanChange: Boolean);
var
  CandidatePath: string;
  CurrentItem: IShellItem;
  CurrentPath: string;
  Dialog: TFileOpenDialog;
begin
  CanChange := True;
  if not (Sender is TFileOpenDialog) then
    Exit;

  Dialog := TFileOpenDialog(Sender);
  CandidatePath := ShellItemPath(Dialog.ShellItem);
  if (CandidatePath = '') or (not TDirectory.Exists(CandidatePath)) then
    Exit;

  CurrentItem := nil;
  if (Dialog.Dialog = nil) or
    (Dialog.Dialog.GetCurrentSelection(CurrentItem) <> S_OK) then
    Exit;

  CurrentPath := ShellItemPath(CurrentItem);
  if not SameText(CurrentPath, CandidatePath) then
    Exit;

  FSourceDialogSelectedPath := CandidatePath;
  CanChange := False;
  Dialog.Dialog.Close(S_OK);
end;

function TMainForm.ShowSourceBrowser(out SelectedPath: string): Boolean;
var
  Dialog: TFileOpenDialog;
  DialogAccepted: Boolean;
  FileType: TFileTypeItem;
  StartDir: string;
begin
  Result := False;
  SelectedPath := '';

  if Trim(FInputEdit.Text) <> '' then
  begin
    if TDirectory.Exists(FInputEdit.Text) then
      StartDir := FInputEdit.Text
    else if TFile.Exists(FInputEdit.Text) then
      StartDir := ExtractFileDir(FInputEdit.Text)
    else
      StartDir := ExtractFileDir(FInputEdit.Text);
  end;
  if (StartDir = '') or (not TDirectory.Exists(StartDir)) then
    StartDir := FLastInputDirectory;
  if (StartDir = '') or (not TDirectory.Exists(StartDir)) then
    StartDir := GetCurrentDir;

  Dialog := TFileOpenDialog.Create(Self);
  try
    FSourceDialogSelectedPath := '';
    Dialog.Title := TextOf('Choose source path');
    Dialog.OkButtonLabel := TextOf('Select');
    Dialog.DefaultFolder := StartDir;
    Dialog.FileTypeIndex := 1;
    Dialog.Options := [fdoPathMustExist, fdoFileMustExist, fdoForceFileSystem];
    FileType := Dialog.FileTypes.Add;
    FileType.DisplayName := TextOf('All files');
    FileType.FileMask := '*.*';
    Dialog.OnFolderChanging := SourceFolderChanging;
    DialogAccepted := Dialog.Execute(Handle);
    if DialogAccepted or (FSourceDialogSelectedPath <> '') then
    begin
      if FSourceDialogSelectedPath <> '' then
        SelectedPath := FSourceDialogSelectedPath
      else
        SelectedPath := Dialog.FileName;

      Result := (SelectedPath <> '') and
        (TFile.Exists(SelectedPath) or TDirectory.Exists(SelectedPath));
      if Result then
      begin
        if TDirectory.Exists(SelectedPath) then
          FLastInputDirectory := SelectedPath
        else
          FLastInputDirectory := ExtractFileDir(SelectedPath);
      end;
    end;
  finally
    Dialog.Free;
    FSourceDialogSelectedPath := '';
  end;
end;

function TMainForm.ResolvedDictionary(const Budget: UInt64): UInt64;
var N: Int64;
begin
  if FDictionaryIndex=Length(DictionaryMbValues)+1 then
    Exit(GuiAutomaticDictionary(FLevelIndex,Max(1,FThreadsCombo.RequestedWorkers),Budget));
  if FDictionaryIndex<Length(DictionaryMbValues) then
    Exit(UInt64(DictionaryMbValues[FDictionaryIndex]) shl 20);
  if (FDictionaryCustomEdit=nil) or not TryStrToInt64(Trim(FDictionaryCustomEdit.Text),N) or
    (N<1) or (N>4095) then raise EArgumentException.Create(TextOf('Enter a dictionary size from 1 to 4095 MB.'));
  Result:=UInt64(N) shl 20;
end;

procedure TMainForm.SavePackingPreference;
const Containers: array[0..3] of string=('lzma','lzma2','xz','7z');
      Checks: array[0..3] of string=('none','CRC32','CRC64','SHA256');
var P: TGuiPackingPreferences; N: Integer;
begin
  if (FThreadsCombo=nil) or (FDictionaryCustomEdit=nil) then Exit;
  FThreadsCombo.CommitInput(False);
  P:=DefaultPackingPreferences;
  P.Container:=Containers[FContainerIndex];P.Level:=FLevelIndex;
  P.Threads:=FThreadsCombo.RequestedWorkers;P.Check:=Checks[FCheckIndex];
  if FDictionaryIndex=Length(DictionaryMbValues)+1 then P.DictionaryMode:='auto'
  else if FDictionaryIndex=Length(DictionaryMbValues) then
  begin
    if not TryStrToInt(Trim(FDictionaryCustomEdit.Text),N) or (N<1) or (N>4095) then Exit;
    P.DictionaryMode:='custom';P.DictionaryMiB:=N;
  end
  else begin P.DictionaryMode:='preset';P.DictionaryMiB:=DictionaryMbValues[FDictionaryIndex];end;
  SavePackingPreferences(P);
end;

procedure TMainForm.LoadLanguagePreference;
var
  FileName: string;
  Preference: string;
  Ini: TMemIniFile;
  Language: TGuiLanguage;
begin
  FPreferredLanguage := -1;
  FLanguage := DetectGuiLanguage;
  try
    FileName := GuiLanguagePreferencePath;
    if (FileName = '') or not FileExists(FileName) then
      Exit;
    Ini := TMemIniFile.Create(FileName, TEncoding.UTF8);
    try
      Preference := Trim(Ini.ReadString('Interface', 'Language', 'auto'));
      for Language := Low(TGuiLanguage) to High(TGuiLanguage) do
        if SameText(Preference, GuiLanguageCodes[Language]) then
        begin
          FPreferredLanguage := Ord(Language);
          FLanguage := Language;
          Break;
        end;
    finally
      Ini.Free;
    end;
  except
    // A damaged or inaccessible preference must not prevent startup.
    FPreferredLanguage := -1;
    FLanguage := DetectGuiLanguage;
  end;
end;

procedure TMainForm.SaveLanguagePreference;
var
  FileName: string;
  Preference: string;
  Ini: TMemIniFile;
begin
  FileName := GuiLanguagePreferencePath;
  if FileName = '' then
    raise EInOutError.Create('Windows per-user application data folder is unavailable.');
  TDirectory.CreateDirectory(ExtractFileDir(FileName));
  if FPreferredLanguage < 0 then
    Preference := 'auto'
  else
    Preference := GuiLanguageCodes[TGuiLanguage(FPreferredLanguage)];
  Ini := TMemIniFile.Create(FileName, TEncoding.UTF8);
  try
    Ini.WriteString('Interface', 'Language', Preference);
    Ini.UpdateFile;
  finally
    Ini.Free;
  end;
end;

procedure TMainForm.ApplyLanguage(const PreferredLanguage: Integer);
var
  I: Integer;
  NewLanguage: TGuiLanguage;
begin
  if (FTask <> nil) or BenchmarkBusy then
    Exit;
  if (PreferredLanguage >= Ord(Low(TGuiLanguage))) and
    (PreferredLanguage <= Ord(High(TGuiLanguage))) then
  begin
    FPreferredLanguage := PreferredLanguage;
    NewLanguage := TGuiLanguage(PreferredLanguage);
  end
  else
  begin
    FPreferredLanguage := -1;
    NewLanguage := DetectGuiLanguage;
  end;
  FLanguage := NewLanguage;
  FLanguageButton.Caption := UpperCase(GuiLanguageCodes[FLanguage]);
  FLanguageButton.Hint := TextOf('Language') + ': ' +
    GuiLanguageNames[FLanguage];
  if FPreferredLanguage < 0 then
    FLanguageButton.Hint := FLanguageButton.Hint + ' – ' +
      TextOf('Auto (Windows)');
  FAboutButton.Caption := TextOf('About');
  FWindowButtons[wbMinimize].Hint := TextOf('Minimize');
  FWindowButtons[wbMaximize].Hint := TextOf('Maximize');
  FWindowButtons[wbClose].Hint := TextOf('Close');
  FCompressModeButton.Caption := TextOf('Compression');
  FDecompressModeButton.Caption := TextOf('Extraction');
  FBenchmarkModeButton.Caption := TextOf('Benchmark');
  FInputLabel.Caption := TextOf('Source path');
  FOutputLabel.Caption := TextOf('Output path');
  FInputEdit.TextHint := TextOf('Select path');
  FOutputEdit.TextHint := TextOf('Select output file');
  FInputBrowseButton.Caption := TextOf('Browse')+'…';
  FOutputBrowseButton.Caption := TextOf('Browse')+'…';
  FContainerLabel.Caption := TextOf('Container');
  FLevelLabel.Caption := TextOf('Compression level');
  FDictionaryLabel.Caption := TextOf('Dictionary');
  FCheckLabel.Caption := TextOf('Check')+' (XZ)';
  FThreadsLabel.Caption := TextOf('Threads');
  UpdateAutoThreads;
  FCheckButtons[0].Caption := TextOf('none');
  FDictionaryCombo.Items.BeginUpdate;
  try
    for I := Low(DictionaryMbValues) to High(DictionaryMbValues) do
      FDictionaryCombo.Items[I] := DictionaryCaption(DictionaryMbValues[I]);
    FDictionaryCombo.Items[Length(DictionaryMbValues)] :=
      TextOf('Custom') + ' (' + TextOf('MB') + ')';
    FDictionaryCombo.ItemIndex := FDictionaryIndex;
  finally
    FDictionaryCombo.Items.EndUpdate;
  end;
  FDictionaryCustomEdit.TextHint := TextOf('MB');
  FCancelButton.Caption := TextOf('Cancel');
  ApplyBenchmarkLanguage;
  // Match an idle mode change: clear transient results, retain paths/options.
  ResetActivityState;
  UpdateModeButtons;
  UpdateOptionButtons;
  UpdateStartState;
end;

procedure TMainForm.LanguageButtonClick(Sender: TObject);
var Languages: TStringList;
    Colors: TLanguagePickerColors;
    Language: TGuiLanguage;
begin
  if (FTask<>nil) or BenchmarkBusy then Exit;
  Application.CancelHint;
  if (FLanguagePopup<>nil) and FLanguagePopup.Visible then
  begin FLanguagePopup.Hide; Exit; end;
  FreeAndNil(FLanguagePopup);
  Languages:=TStringList.Create;
  try
    Languages.Add(TextOf('Auto (Windows)'));
    for Language:=Low(TGuiLanguage) to High(TGuiLanguage) do
      Languages.Add(GuiLanguageNames[Language]+'  '+UpperCase(GuiLanguageCodes[Language]));
    Colors.Background:=UiInput;
    Colors.Text:=UiText;
    Colors.Muted:=UiSubtleText;
    Colors.Selection:=UiSelection;
    Colors.Hover:=UiSurfaceHigh;
    Colors.Accent:=UiAccent;
    FLanguagePopup:=ShowLanguagePicker(Self,FLanguageButton,Languages,FPreferredLanguage+1,
      TextOf('Find language'),TextOf('No languages found'),Colors,
      procedure(const Chosen: Integer)
      begin
        ApplyLanguage(Chosen-1);
        try SaveLanguagePreference;
        except on E: Exception do
          ShowErrorDialog(TextOf('Could not save the language preference.'),DescribeGuiFailure(E,Ord(FLanguage)).Details);
        end;
      end,
      procedure(Keyboard: Boolean)
      begin
        TRoundedPanel(FLanguageButton).FocusWithCue(Keyboard);
      end);
  finally Languages.Free; end;
end;

procedure TMainForm.BuildUi;
var
  BodyPanel: TScrollBox;
  TitleBarPanel: TPanel;
  TitleBorderPanel: TPanel;
  TitleButton: TWindowButton;
  I: Integer;
  Initial: TGuiPackingPreferences;

  function AddText(const Parent: TWinControl; const ACaption: string;
    const ASize: Integer = UiSmallText; const Muted: Boolean = False;
    const Semibold: Boolean = False): TLabel;
  begin
    Result := TLabel.Create(Self);
    Result.Parent := Parent;
    Result.Caption := ACaption;
    Result.AutoSize := False;
    Result.WordWrap := False;
    Result.Transparent := True;
    Result.StyleElements := [];
    RegisterLogicalFont(FLogicalFonts, Result.Font, ASize, Semibold);
    Result.EllipsisPosition := epEndEllipsis;
    if Muted then
      Result.Font.Color := UiMutedText
    else
      Result.Font.Color := UiText;
  end;

  function MakeSurface(const Parent: TWinControl;
    const SurfaceColor: TColor = UiSurface; const Framed: Boolean = False): TPanel;
  begin
    Result := TRoundedPanel.Create(Self);
    Result.Parent := Parent;
    Result.Color := SurfaceColor;
    if Framed then
    begin
      TRoundedPanel(Result).CornerRadius := 6;
      TRoundedPanel(Result).BorderColor := UiBorder;
    end
    else
    begin
      TRoundedPanel(Result).CornerRadius := 0;
      TRoundedPanel(Result).BorderColor := clNone;
      TRoundedPanel(Result).BorderWidth := 0;
    end;
  end;

  function MakeButton(const Parent: TWinControl; const ACaption: string;
    const Primary: Boolean; const AOnClick: TNotifyEvent): TPanel;
  begin
    Result := MakeSurface(Parent, UiSurfaceHigh, True);
    Result.Caption := ACaption;
    Result.Alignment := taCenter;
    RegisterLogicalFont(FLogicalFonts, Result.Font, UiBodyText, True);
    Result.TabStop := True;
    Result.Cursor := crHandPoint;
    Result.OnClick := AOnClick;
    SetPanelButtonEnabled(Result, True, Primary);
  end;

  procedure StyleEdit(const Edit: TEdit; const HintText: string);
  begin
    Edit.AutoSize := True;
    Edit.BorderStyle := bsNone;
    Edit.Ctl3D := False;
    Edit.Color := UiInput;
    RegisterLogicalFont(FLogicalFonts, Edit.Font, UiBodyText);
    Edit.Font.Color := UiText;
    Edit.StyleElements := [];
    TGuiEditHint.CreateForEdit(Edit,UiSubtleText);
    Edit.TextHint := HintText;
    Edit.OnEnter := EditEnter;
    Edit.OnExit := EditExit;
  end;

{$I Lzma2BenchmarkBuild.inc}

begin
  Caption := GuiProductName;
  Position := poScreenCenter;
  BorderStyle := bsNone;
  Scaled := True;
  Width := UiDefaultWidth;
  Height := UiDefaultHeight;
  Constraints.MinWidth := UiMinimumWidth;
  Constraints.MinHeight := UiMinimumHeight;
  DoubleBuffered := True;
  Color := UiSurface;
  OnMouseDown := TitleBarMouseDown;
  OnContextPopup := TitleBarContextPopup;
  RegisterLogicalFont(FLogicalFonts, Font, UiBodyText);
  Font.Color := UiText;
  FModeIndex := 0;
  Initial:=LoadPackingPreferences;
  if Initial.Container='lzma' then FContainerIndex:=0
  else if Initial.Container='lzma2' then FContainerIndex:=1
  else if Initial.Container='xz' then FContainerIndex:=2 else FContainerIndex:=3;
  FLevelIndex:=Initial.Level;
  if Initial.Check='none' then FCheckIndex:=0 else if Initial.Check='CRC32' then FCheckIndex:=1
  else if Initial.Check='SHA256' then FCheckIndex:=3 else FCheckIndex:=2;
  FDictionaryIndex:=Length(DictionaryMbValues)+1;
  if Initial.DictionaryMode='custom' then FDictionaryIndex:=Length(DictionaryMbValues)
  else if Initial.DictionaryMode='preset' then
    for I:=Low(DictionaryMbValues) to High(DictionaryMbValues) do
      if DictionaryMbValues[I]=Initial.DictionaryMiB then FDictionaryIndex:=I;
  FProgressPercent := 0;
  FProgressError := False;

  TitleBarPanel := TPanel.Create(Self);
  TitleBarPanel.Parent := Self;
  TitleBarPanel.Align := alTop;
  TitleBarPanel.Height := UiHeaderHeight;
  TitleBarPanel.BevelOuter := bvNone;
  TitleBarPanel.ParentBackground := False;
  TitleBarPanel.Color := UiChrome;
  TitleBarPanel.StyleElements := [];
  TitleBarPanel.OnMouseDown := TitleBarMouseDown;
  TitleBarPanel.OnMouseUp := TitleBarMouseUp;
  TitleBarPanel.OnContextPopup := TitleBarContextPopup;
  TitleBarPanel.OnResize := LayoutTitleBar;
  TitleBorderPanel := TPanel.Create(Self);
  TitleBorderPanel.Parent := TitleBarPanel;
  TitleBorderPanel.Align := alBottom;
  TitleBorderPanel.Height := 1;
  TitleBorderPanel.BevelOuter := bvNone;
  TitleBorderPanel.ParentBackground := False;
  TitleBorderPanel.Color := UiBorder;
  TitleBorderPanel.StyleElements := [];
  TitleBorderPanel.Visible := False;
  TitleBorderPanel.OnMouseDown := TitleBarMouseDown;
  TitleBorderPanel.OnMouseUp := TitleBarMouseUp;
  TitleBorderPanel.OnContextPopup := TitleBarContextPopup;

  FTitleIcon := TApplicationMark.Create(Self);
  FTitleIcon.Parent := TitleBarPanel;
  FTitleIcon.ParentColor := False;FTitleIcon.Color := UiChrome;
  FTitleIcon.SetBounds(16, 8, 20, 20);
  FTitleIcon.OnMouseDown := TitleBarMouseDown;
  FTitleIcon.OnMouseUp := TitleBarMouseUp;
  FTitleIcon.OnContextPopup := TitleBarContextPopup;
  FTitleLabel := AddText(TitleBarPanel, GuiProductName, UiTitleText, False, True);
  FTitleLabel.SetBounds(48, 0, 216, UiHeaderHeight);
  FTitleLabel.Layout := tlCenter;
  FTitleLabel.OnMouseDown := TitleBarMouseDown;
  FTitleLabel.OnMouseUp := TitleBarMouseUp;
  FTitleLabel.OnContextPopup := TitleBarContextPopup;

  TitleBarPanel.DisableAlign;
  try
    FAboutButton := MakeButton(TitleBarPanel,TextOf('About'),False,AboutClick);
    FAboutButton.Width := 112;
    FAboutButton.Left := 72;
    FAboutButton.Align := alNone;
    TRoundedPanel(FAboutButton).CornerRadius := 0;
    TRoundedPanel(FAboutButton).BorderColor := clNone;
    TRoundedPanel(FAboutButton).BorderWidth := 0;
    FAboutButton.Color := UiChrome;
    FLanguageButton := MakeButton(TitleBarPanel, '', False, LanguageButtonClick);
    FLanguageButton.Width := 72;
    TRoundedPanel(FLanguageButton).GlyphKind := pgLanguage;
    FLanguageButton.Left := 0;
    FLanguageButton.Align := alNone;
    FLanguageButton.TabOrder := 0;
    FAboutButton.TabOrder := 1;
    FLanguageButton.ShowHint := True;
    TRoundedPanel(FLanguageButton).CornerRadius := 0;
    TRoundedPanel(FLanguageButton).BorderColor := clNone;
    TRoundedPanel(FLanguageButton).BorderWidth := 0;
    FLanguageButton.Color := UiChrome;

    for I := Ord(Low(TWindowButtonKind)) to Ord(High(TWindowButtonKind)) do
    begin
      TitleButton := TWindowButton.Create(Self);
      TitleButton.Parent := TitleBarPanel;
      TitleButton.Width := 46;
      TitleButton.Left := FAboutButton.Width + FLanguageButton.Width + I * TitleButton.Width;
      TitleButton.Align := alNone;
      TitleButton.Kind := TWindowButtonKind(I);
      TitleButton.ShowHint := True;
      FWindowButtons[TitleButton.Kind] := TitleButton;
      case TitleButton.Kind of
        wbMinimize:
          begin
            TitleButton.Hint := TextOf('Minimize');
            TitleButton.OnClick := MinimizeWindowClick;
          end;
        wbMaximize:
          begin
            TitleButton.Hint := TextOf('Maximize');
            TitleButton.OnClick := MaximizeWindowClick;
          end;
        wbClose:
          begin
            TitleButton.Hint := TextOf('Close');
            TitleButton.OnClick := CloseWindowClick;
          end;
      end;
    end;

  finally
    TitleBarPanel.EnableAlign;
  end;
  TitleBorderPanel.BringToFront;

  FResizeGrip := TGuiResizeGrip.Create(Self);
  FResizeGrip.Parent := Self;
  FResizeGrip.Height := UiResizeGripSize;
  FResizeGrip.Align := alBottom;

  BodyPanel := TScrollBox.Create(Self);
  BodyPanel.Parent := Self;
  BodyPanel.Align := alClient;
  BodyPanel.BorderStyle := bsNone;
  BodyPanel.Ctl3D := False;
  BodyPanel.HorzScrollBar.Visible := False;
  BodyPanel.VertScrollBar.Smooth := True;
  BodyPanel.Color := UiSurface;
  BodyPanel.StyleElements := [];
  BodyPanel.Padding.SetBounds(UiContentPadding, 24, UiContentPadding, UiBottomPadding-UiResizeGripSize);
  SetWindowTheme(BodyPanel.Handle,'DarkMode_Explorer',nil);
  FMainPanel := TPanel.Create(Self);
  FMainPanel.Parent := BodyPanel;
  FMainPanel.Align := alTop;
  FMainPanel.Height := UiModeTop+UiBenchmarkHeight;
  FMainPanel.BevelOuter := bvNone;
  FMainPanel.ParentBackground := False;
  FMainPanel.Color := UiSurface;
  FMainPanel.StyleElements := [];
  FMainPanel.OnResize := MainPanelResize;
  FFilesPanel := MakeSurface(FMainPanel);
  FFilesPanel.Anchors := [akLeft, akTop, akRight, akBottom];
  FModePanel := MakeSurface(FFilesPanel, UiInput, True);
  FCompressModeButton := MakeButton(FModePanel, TextOf('Compression'), False, ModeClick);
  FCompressModeButton.Tag := 0;
  FDecompressModeButton := MakeButton(FModePanel, TextOf('Extraction'), False, ModeClick);
  FDecompressModeButton.Tag := 1;
  FBenchmarkModeButton := MakeButton(FModePanel, TextOf('Benchmark'), False, ModeClick);
  FBenchmarkModeButton.Tag := 2;

  FInputRow := MakeSurface(FFilesPanel);
  FInputLabel := AddText(FInputRow, TextOf('Source path'), UiBodyText, False, True);
  FInputShell := MakeSurface(FInputRow, UiInput, True);
  FInputEdit := TEdit.Create(Self);
  FInputEdit.Parent := FInputShell;
  StyleEdit(FInputEdit, TextOf('Select path'));
  FInputEdit.ShowHint := True;
  FInputEdit.OnChange := EditChange;
  FInputLabel.FocusControl := FInputEdit;
  FInputBrowseButton := MakeButton(FInputRow, TextOf('Browse'), False, BrowseInputClick);
  TRoundedPanel(FInputBrowseButton).GlyphKind := pgNone;
  FOutputRow := MakeSurface(FFilesPanel);
  FOutputLabel := AddText(FOutputRow, TextOf('Output path'), UiBodyText, False, True);
  FOutputShell := MakeSurface(FOutputRow, UiInput, True);
  FOutputEdit := TEdit.Create(Self);
  FOutputEdit.Parent := FOutputShell;
  StyleEdit(FOutputEdit, TextOf('Select output file'));
  FOutputEdit.ShowHint := True;
  FOutputEdit.OnChange := EditChange;
  FOutputLabel.FocusControl := FOutputEdit;
  FOutputBrowseButton := MakeButton(FOutputRow, TextOf('Browse'), False, BrowseOutputClick);
  TRoundedPanel(FOutputBrowseButton).GlyphKind := pgNone;

  FSettingsPanel := MakeSurface(FFilesPanel);
  FContainerLabel := AddText(FSettingsPanel, TextOf('Container'), UiBodyText, True);
  FLevelLabel := AddText(FSettingsPanel, TextOf('Compression level'), UiBodyText, True);
  FDictionaryLabel := AddText(FSettingsPanel, TextOf('Dictionary'), UiBodyText, True);
  FCheckLabel := AddText(FSettingsPanel, TextOf('Check'), UiBodyText, True);
  FThreadsLabel := AddText(FSettingsPanel, TextOf('Threads'), UiBodyText, True);
  FContainerGroup := MakeSurface(FSettingsPanel, UiInput, True);
  FCheckGroup := MakeSurface(FSettingsPanel, UiInput, True);
  FContainerButtons[0] := MakeButton(FContainerGroup, 'LZMA', False, ContainerClick);
  FContainerButtons[1] := MakeButton(FContainerGroup, 'LZMA2', False, ContainerClick);
  FContainerButtons[2] := MakeButton(FContainerGroup, 'XZ', False, ContainerClick);
  FContainerButtons[3] := MakeButton(FContainerGroup, '7Z', False, ContainerClick);
  for I := Low(FContainerButtons) to High(FContainerButtons) do
    FContainerButtons[I].Tag := I;
  FCheckButtons[0] := MakeButton(FCheckGroup, TextOf('none'), False, CheckClick);
  FCheckButtons[1] := MakeButton(FCheckGroup, 'CRC32', False, CheckClick);
  FCheckButtons[2] := MakeButton(FCheckGroup, 'CRC64', False, CheckClick);
  FCheckButtons[3] := MakeButton(FCheckGroup, 'SHA-256', False, CheckClick);
  for I := Low(FCheckButtons) to High(FCheckButtons) do
    FCheckButtons[I].Tag := I;
  FLevelCombo := TOptionCombo.Create(Self);
  FLevelCombo.Parent := FSettingsPanel;
  for I := Ord(Low(TLzma2CompressionLevel)) to Ord(High(TLzma2CompressionLevel)) do
    FLevelCombo.Items.Add(IntToStr(I));
  FLevelCombo.ItemIndex := FLevelIndex;
  FLevelCombo.OnChange := LevelChange;
  FDictionaryCombo := TOptionCombo.Create(Self);
  FDictionaryCombo.Parent := FSettingsPanel;
  for I := Low(DictionaryMbValues) to High(DictionaryMbValues) do
    FDictionaryCombo.Items.Add(DictionaryCaption(DictionaryMbValues[I]));
  FDictionaryCombo.Items.Add(TextOf('Custom') + ' (' + TextOf('MB') + ')');
  FDictionaryCombo.Items.Add(TextOf('Auto'));
  FDictionaryCombo.ItemIndex := FDictionaryIndex;
  FDictionaryCombo.OnChange := DictionaryChange;
  FDictionaryCustomShell := MakeSurface(FSettingsPanel, UiInput, True);
  FDictionaryCustomShell.Visible := False;
  FDictionaryCustomEdit := TEdit.Create(Self);
  FDictionaryCustomEdit.Parent := FDictionaryCustomShell;
  StyleEdit(FDictionaryCustomEdit, 'MB');
  FDictionaryCustomEdit.Text := IntToStr(Initial.DictionaryMiB);
  FDictionaryCustomEdit.OnChange := DictionaryCustomEditChange;
  FThreadsCombo := TThreadChoiceCombo.Create(Self);
  FThreadsCombo.Parent := FSettingsPanel;
  FThreadsCombo.Configure(GuiProcessorCount,TextOf('Auto'),TextOf('Other...'),TextOf('Manual: %d'));
  FThreadsCombo.RequestedWorkers := Initial.Threads;
  FThreadsCombo.OnChange := ThreadsChange;
  FLevelLabel.FocusControl := FLevelCombo;
  FDictionaryLabel.FocusControl := FDictionaryCombo;
  FThreadsLabel.FocusControl := FThreadsCombo;

  FContainerGroup.TabOrder := 0;
  FCheckGroup.TabOrder := FContainerGroup.TabOrder + 1;
  for I := Low(FContainerButtons) to High(FContainerButtons) do
    FContainerButtons[I].TabOrder := I;
  for I := Low(FCheckButtons) to High(FCheckButtons) do
    FCheckButtons[I].TabOrder := I;
  FLevelCombo.TabOrder := FCheckGroup.TabOrder + 1;
  FDictionaryCombo.TabOrder := FLevelCombo.TabOrder + 1;
  FDictionaryCustomShell.TabOrder := FDictionaryCombo.TabOrder + 1;
  FThreadsCombo.TabOrder := FDictionaryCustomShell.TabOrder + 1;

  FActivityPanel := MakeSurface(FFilesPanel);
  FStartButton := MakeButton(FActivityPanel, TextOf('Start compression'), True, StartClick);
  FCancelButton := MakeButton(FActivityPanel, TextOf('Cancel'), False, CancelClick);
  FCancelButton.Visible := False;
  SetPanelButtonEnabled(FCancelButton, False, False);
  FProgressTrack := MakeSurface(FActivityPanel, UiBorder);
  FProgressTrack.OnResize := ProgressTrackResize;
  FProgressTrack.Visible := False;
  FProgressFill := MakeSurface(FProgressTrack, UiAccent);
  FProgressFill.Visible := False;
  FProgressLabel := AddText(FActivityPanel, '', UiBodyText, False, True);
  FProgressLabel.Alignment := taRightJustify;
  FProgressLabel.Layout := tlCenter;
  FProgressLabel.Visible := False;
  FStatusLabel := AddText(FActivityPanel, '', UiBodyText, False, True);
  FStatusLabel.ShowHint := True;
  FStatusLabel.WordWrap := True;
  FStatusLabel.Visible := False;
  FStatsLabel := AddText(FActivityPanel, '', UiBodyText, True);
  FStatsLabel.WordWrap := True;
  FStatsLabel.ShowHint := True;
  FStatsLabel.Visible := False;
  FReadyLabel := AddText(FActivityPanel, '', UiBodyText, True);
  FReadyLabel.Layout := tlCenter;
  FReadyLabel.EllipsisPosition := epEndEllipsis;
  FReadyLabel.ShowHint := True;

  BuildBenchmarkControls;
  ApplyLanguage(FPreferredLanguage);
  LayoutMainPanels;
  SetProgressVisual(0, False);
  UpdateStartState;
  ActiveControl := FInputEdit;
  FPollTimer := TTimer.Create(Self);
  FPollTimer.Enabled := False;
  FPollTimer.Interval := 100;
  FPollTimer.OnTimer := PollTimerTimer;
end;

function TMainForm.BuildOptions: TLzma2Options;
var
  Budget: UInt64;
  Threads: Integer;
begin
  Result := TLzma2.DefaultOptions;
  case FContainerIndex of
    1: Result.Container := lcRawLzma2;
    2: Result.Container := lcXz;
    3: Result.Container := lc7z;
  else
    Result.Container := lcLzma;
  end;
  Result.Level := TLzma2CompressionLevel(FLevelIndex);
  Budget:=GuiMemoryBudget;
  Result.DictionarySize:=ResolvedDictionary(Budget);
  Threads := FThreadsCombo.RequestedWorkers;
  if Threads < 0 then Threads := 0;
  if Threads = 0 then
  begin
    Result.MemoryLimit := Budget;
    Threads := AutoThreadCount(Result, Result.MemoryLimit, GuiProcessorCount);
  end;
  if FDictionaryIndex=Length(DictionaryMbValues)+1 then Result.MemoryLimit:=Budget;
  Result.ThreadCount := Threads;
  case FCheckIndex of
    0: Result.Check := lzCheckNone;
    1: Result.Check := lzCheckCrc32;
    3: Result.Check := lzCheckSha256;
  else
    Result.Check := lzCheckCrc64;
  end;
end;

procedure TMainForm.BrowseInputClick(Sender: TObject);
var
  SelectedPath: string;
begin
  try
    if ShowSourceBrowser(SelectedPath) then
    begin
      FInputEdit.Text := SelectedPath;
      if TDirectory.Exists(SelectedPath) and (FContainerIndex <> 3) then
      begin
        FContainerIndex := 3;
        UpdateOptionButtons;
      end;
      UpdateDefaultOutputPath(False);
    end;
  except
    on E: Exception do
    begin
      ReportException(E);
    end;
  end;
end;

procedure TMainForm.BrowseOutputClick(Sender: TObject);
var
  Dialog: TFileSaveDialog;
  Extension: string;
  FileType: TFileTypeItem;
  SuggestedPath: string;
begin
  Dialog := TFileSaveDialog.Create(Self);
  try
    Dialog.Title := TextOf('Choose output file');
    Dialog.Options := [fdoPathMustExist, fdoOverwritePrompt];
    UpdateDefaultOutputPath(False);
    SuggestedPath := Trim(FOutputEdit.Text);
    if SuggestedPath <> '' then
    begin
      Dialog.DefaultFolder := ExtractFileDir(SuggestedPath);
      Dialog.FileName := ExtractFileName(SuggestedPath);
    end;
    if FModeIndex = 0 then
    begin
      case FContainerIndex of
        0: Extension := 'lzma';
        1: Extension := 'lzma2';
        3: Extension := '7z';
      else
        Extension := 'xz';
      end;
      Dialog.DefaultExtension := Extension;
      FileType := Dialog.FileTypes.Add;
      FileType.DisplayName := UpperCase(Extension) + TextOf(' archive');
      FileType.FileMask := '*.' + Extension;
      FileType := Dialog.FileTypes.Add;
      FileType.DisplayName := TextOf('All files');
      FileType.FileMask := '*.*';
    end;
    if Dialog.Execute then
    begin
      FLastOutputDirectory := ExtractFileDir(Dialog.FileName);
      SetOutputPathText(Dialog.FileName, False);
      ResetActivityState;
      UpdateStartState;
    end;
  except
    on E: Exception do
    begin
      ReportException(E);
    end;
  end;
  Dialog.Free;
end;

procedure TMainForm.SetBusy(const Busy: Boolean);
var
  CanStart: Boolean;
  I: Integer;
begin
  CanStart := (not Busy) and (Trim(FInputEdit.Text) <> '') and
    (Trim(FOutputEdit.Text) <> '') and
    ((FModeIndex<>0) or FThreadsCombo.InputValid);
  FLanguageButton.Enabled := not Busy;
  FAboutButton.Enabled := not Busy;
  if Busy then
    FLanguageButton.Font.Color := UiSubtleText
  else
    FLanguageButton.Font.Color := UiText;
  FInputEdit.ReadOnly := Busy;
  FOutputEdit.ReadOnly := Busy;
  if Busy then
    FReadyLabel.Visible := False;
  FInputBrowseButton.Enabled := not Busy;
  FOutputBrowseButton.Enabled := not Busy;
  FCompressModeButton.Enabled := not Busy;
  FDecompressModeButton.Enabled := not Busy;
  FBenchmarkModeButton.Enabled := not Busy;
  for I := Low(FContainerButtons) to High(FContainerButtons) do
    FContainerButtons[I].Enabled := not Busy;
  FLevelCombo.Enabled := not Busy;
  for I := Low(FCheckButtons) to High(FCheckButtons) do
    FCheckButtons[I].Enabled := not Busy;
  FDictionaryCombo.Enabled := not Busy;
  FThreadsCombo.Enabled := not Busy;
  if FDictionaryCustomEdit <> nil then
    FDictionaryCustomEdit.Enabled := not Busy and FDictionaryCustomShell.Visible;
  SetPanelButtonEnabled(FInputBrowseButton, not Busy, False);
  SetPanelButtonEnabled(FOutputBrowseButton, not Busy, False);
  FStartButton.Visible := not Busy;
  FCancelButton.Visible := Busy;
  FCancelButton.Caption := TextOf('Cancel');
  SetPanelButtonEnabled(FStartButton, CanStart, True);
  SetPanelButtonEnabled(FCancelButton, Busy, False);
  UpdateModeButtons;
  UpdateOptionButtons;
end;

procedure TMainForm.CloseStreams;
begin
  FreeAndNil(FOutputStream);
  FreeAndNil(FInputStream);
end;

function TMainForm.BuildTempOutputPath(const FinalPath: string): string;
var
  Dir: string;
  Name: string;
  Counter: Integer;
begin
  Dir := ExtractFileDir(FinalPath);
  if Dir = '' then
    Dir := GetCurrentDir;
  Name := ExtractFileName(FinalPath);
  Counter := 0;
  repeat
    Result := TPath.Combine(Dir, Format('%s.tmp.%d.%d', [Name, GetCurrentProcessId, Counter]));
    Inc(Counter);
  until not TFile.Exists(Result);
end;

procedure TMainForm.FinalizeOutputFile;
begin
  if FTempOutputPath = '' then
    Exit;
  if TFile.Exists(FOutputEdit.Text) then
    TFile.Delete(FOutputEdit.Text);
  TFile.Move(FTempOutputPath, FOutputEdit.Text);
  FTempOutputPath := '';
end;

procedure TMainForm.CleanupOutputFile;
begin
  try
    if (FTempOutputPath <> '') and TFile.Exists(FTempOutputPath) then
      TFile.Delete(FTempOutputPath);
  finally
    FTempOutputPath := '';
  end;
end;

procedure TMainForm.StartClick(Sender: TObject);
var
  Entries: TArray<TLzma7zEncodeEntry>;
  EntryOffsets: TArray<UInt64>;
  EntrySizes: TArray<UInt64>;
  CurrentEntryIndex: Integer;
  I: Integer;
  InputIsDirectory: Boolean;
  InputPath: string;
  Options: TLzma2Options;
  SourcePaths: TArray<string>;
  TotalInputBytes: UInt64;
begin
  if (FModeIndex=0) and not FThreadsCombo.CommitInput then Exit;
  InputPath := Trim(FInputEdit.Text);
  if InputPath = '' then
  begin
    SetInlineStatus(TextOf('Choose a source path.'), True);
    ShowErrorDialog(TextOf('Choose a source path.'));
    Exit;
  end;
  if Trim(FOutputEdit.Text) = '' then
  begin
    UpdateDefaultOutputPath(True);
    if Trim(FOutputEdit.Text) = '' then
    begin
      SetInlineStatus(TextOf('Choose an output file.'), True);
      ShowErrorDialog(TextOf('Choose an output file.'));
      Exit;
    end;
  end;
  if ExtractFileExt(FOutputEdit.Text) = '' then
  begin
    UpdateDefaultOutputPath(True);
    if ExtractFileExt(FOutputEdit.Text) = '' then
      SetOutputPathText(FOutputEdit.Text + '.out', FOutputAutoGenerated);
  end;

  ResetActivityState;
  if not TFile.Exists(InputPath) and not TDirectory.Exists(InputPath) then
  begin
    SetInlineStatus(TextOf('Source path was not found.'), True);
    ShowErrorDialog(TextOf('Source path was not found.'));
    Exit;
  end;

  try
    InputIsDirectory := TDirectory.Exists(InputPath);
    if InputIsDirectory and (FModeIndex <> 0) then
      raise EArgumentException.Create(TextOf('Folders can only be compressed into a 7Z archive.'));
    if InputIsDirectory and (FContainerIndex <> 3) then
    begin
      FContainerIndex := 3;
      UpdateOptionButtons;
    end;
    Options := BuildOptions;
    FillChar(FEncodeDiagnostics, SizeOf(FEncodeDiagnostics), 0);
    FillChar(FDecodeDiagnostics, SizeOf(FDecodeDiagnostics), 0);
    Options.EncodeDiagnostics := @FEncodeDiagnostics;
    Options.DecodeDiagnostics := @FDecodeDiagnostics;
    if FModeIndex = 0 then
      Options.ArchiveFileName := ExtractFileName(InputPath);
    CloseStreams;
    CleanupOutputFile;
    if InputIsDirectory then
    begin
      CollectSevenZipSourceEntries(InputPath, Entries, SourcePaths, TotalInputBytes);
      SetLength(EntryOffsets, Length(Entries));
      SetLength(EntrySizes, Length(Entries));
      TotalInputBytes := 0;
      for I := 0 to High(Entries) do
      begin
        EntryOffsets[I] := TotalInputBytes;
        if not Entries[I].IsDirectory then
        begin
          EntrySizes[I] := UInt64(TFile.GetSize(SourcePaths[I]));
          Inc(TotalInputBytes, EntrySizes[I]);
        end;
      end;
      FInputStream := nil;
    end
    else
      FInputStream := TFileStream.Create(InputPath, fmOpenRead or fmShareDenyWrite);
    try
      if ExtractFileDir(FOutputEdit.Text) <> '' then
        TDirectory.CreateDirectory(ExtractFileDir(FOutputEdit.Text));
      FTempOutputPath := BuildTempOutputPath(FOutputEdit.Text);
      FOutputStream := TFileStream.Create(FTempOutputPath, fmCreate);
    except
      CloseStreams;
      CleanupOutputFile;
      raise;
    end;
  except
    on E: Exception do
    begin
      ReportException(E);
      Exit;
    end;
  end;

  if InputIsDirectory then
    FInputSize := TotalInputBytes
  else
    FInputSize := FInputStream.Size;
  TInterlocked.Exchange(FLastIn, UInt64(0));
  TInterlocked.Exchange(FLastOut, UInt64(0));
  TInterlocked.Exchange(FCancelRequested, 0);
  FWatch := TStopwatch.StartNew;
  UpdateProgressUi(0, 0);

  if InputIsDirectory then
  begin
    CurrentEntryIndex := 0;
    FTask := System.Threading.TTask.Run(
      procedure
      begin
        TLzma7z.EncodeEntries(Entries,
          function(const Entry: TLzma7zEncodeEntry; const EntryIndex: Integer): TStream
          begin
            CurrentEntryIndex := EntryIndex;
            if Entry.IsDirectory then
              Exit(nil);
            Result := TFileStream.Create(SourcePaths[EntryIndex], fmOpenRead or fmShareDenyWrite);
          end,
          FOutputStream, Options, zemLzma2,
          procedure(const InBytes: UInt64; const OutBytes: UInt64; var Cancel: Boolean)
          var
            AbsoluteIn: UInt64;
          begin
            if (CurrentEntryIndex >= Low(EntryOffsets)) and (CurrentEntryIndex <= High(EntryOffsets)) then
              AbsoluteIn := EntryOffsets[CurrentEntryIndex] + InBytes
            else
              AbsoluteIn := InBytes;
            TInterlocked.Exchange(FLastIn, AbsoluteIn);
            TInterlocked.Exchange(FLastOut, OutBytes);
            Cancel := TInterlocked.CompareExchange(FCancelRequested, 0, 0) <> 0;
          end);
      end);
  end
  else if FModeIndex = 0 then
    FTask := TLzma2.CompressAsync(
      FInputStream,
      FOutputStream,
      Options,
      procedure(const InBytes: UInt64; const OutBytes: UInt64; var Cancel: Boolean)
      begin
        TInterlocked.Exchange(FLastIn, InBytes);
        TInterlocked.Exchange(FLastOut, OutBytes);
        Cancel := TInterlocked.CompareExchange(FCancelRequested, 0, 0) <> 0;
      end)
  else
    FTask := TLzma2.DecompressAsync(
      FInputStream,
      FOutputStream,
      Options,
      procedure(const InBytes: UInt64; const OutBytes: UInt64; var Cancel: Boolean)
      begin
        TInterlocked.Exchange(FLastIn, InBytes);
        TInterlocked.Exchange(FLastOut, OutBytes);
        Cancel := TInterlocked.CompareExchange(FCancelRequested, 0, 0) <> 0;
      end);

  SetBusy(True);
  SetProgressVisual(0, False);
  FPollTimer.Enabled := True;
end;

procedure TMainForm.CancelClick(Sender: TObject);
begin
  TInterlocked.Exchange(FCancelRequested, 1);
  FCancelButton.Caption := TextOf('Cancelling...');
  SetPanelButtonEnabled(FCancelButton, False, False);
end;

procedure TMainForm.UpdateProgressUi(const InBytes, OutBytes: UInt64);
var
  DisplayIn: UInt64;
  NeedsLayout: Boolean;
  ElapsedMs: Int64;
  Percent: Integer;
  Speed: Double;
  SpeedText: string;
begin
  if csDestroying in ComponentState then
    Exit;
  if FInputSize = 0 then
    Percent := 100
  else
    Percent := Integer(Min(UInt64(100), (InBytes * UInt64(100)) div FInputSize));
  NeedsLayout := not (FStatusLabel.Visible and FStatsLabel.Visible);
  SetProgressVisual(Percent, False);
  FProgressTrack.Visible := True;
  FReadyLabel.Visible := False;
  if FModeIndex = 0 then
    FStatusLabel.Caption := TextOf('Compression')
  else
    FStatusLabel.Caption := TextOf('Extraction');
  FStatusLabel.Hint := FStatusLabel.Caption;
  FStatusLabel.Font.Color := UiText;
  FStatusLabel.Visible := True;
  FStatsLabel.Visible := True;
  DisplayIn := InBytes;
  if (FInputSize > 0) and (DisplayIn > FInputSize) then
    DisplayIn := FInputSize;
  SpeedText := TextOf('speed: –');
  if FWatch.IsRunning then
  begin
    ElapsedMs := FWatch.ElapsedMilliseconds;
    if ElapsedMs > 0 then
    begin
      Speed := InBytes / (ElapsedMs / 1000.0);
      SpeedText := TextOf('speed: ') + GuiFormatRate(Speed, FLanguage);
    end;
  end;
  FStatsLabel.Caption := Format(TextOf('Processed: %s of %s | written: %s | %s'),
    [GuiFormatBytes(DisplayIn, FLanguage), GuiFormatBytes(FInputSize, FLanguage),
     GuiFormatBytes(OutBytes, FLanguage), SpeedText]);
  FStatsLabel.Hint := FStatsLabel.Caption;
  if NeedsLayout then
    LayoutMainPanels;
end;

procedure TMainForm.FinishTask(const ErrorText: string; const Cancelled: Boolean;const DiagnosticDetails:string);
var
  ElapsedMs: Int64;
  OutSize: UInt64;
  Ratio: Double;
  Throughput: Double;
  StatusText: string;
  DetailsText: string;
  DiagnosticsText: string;
  UsedThreads: Integer;
begin
  DetailsText := '';
  DiagnosticsText := '';
  FPollTimer.Enabled := False;
  FWatch.Stop;
  ElapsedMs := FWatch.ElapsedMilliseconds;
  OutSize := 0;
  if FOutputStream <> nil then
    OutSize := FOutputStream.Size;
  if Cancelled then
  begin
    StatusText := TextOf('Cancelled');
    SetProgressVisual(0, False);
  end
  else if ErrorText = '' then
  begin
    UpdateProgressUi(FInputSize, OutSize);
    StatusText := Format(TextOf('Done: %s -> %s'),
      [GuiFormatBytes(FInputSize, FLanguage), GuiFormatBytes(OutSize, FLanguage)]);
    DetailsText := Format(TextOf(' | %d ms'), [ElapsedMs]).Trim([' ', '|']);
    if ElapsedMs > 0 then
    begin
      Throughput := FInputSize / (ElapsedMs / 1000.0);
      DetailsText := GuiFormatRate(Throughput, FLanguage) + ' | ' + DetailsText;
    end;
    if (FInputSize <> 0) and (OutSize <> 0) then
    begin
      Ratio := FInputSize / OutSize;
      DetailsText := DetailsText + Format(TextOf(' | Ratio (input/output): %.3f'), [Ratio]);
    end;
    if FModeIndex = 0 then
      UsedThreads := FEncodeDiagnostics.ActualThreadCount
    else
      UsedThreads := FDecodeDiagnostics.ActualThreadCount;
    if UsedThreads > 0 then
      DetailsText := DetailsText + Format(TextOf(' | Threads: %d'), [UsedThreads]);
    if FModeIndex <> 0 then
      DiagnosticsText := Format(TextOf(' | Decode requested threads: %d | Decode actual threads: %d | Decode used MT: %s | Decode fallback: %s'),
        [FDecodeDiagnostics.RequestedThreadCount, FDecodeDiagnostics.ActualThreadCount,
         BoolToStr(FDecodeDiagnostics.UsedMultiThread, True),
         DecodeFallbackReasonName(FDecodeDiagnostics.FallbackReason)]);
    SetProgressVisual(100, False);
  end
  else
  begin
    StatusText := ErrorText;
    SetProgressVisual(FProgressPercent, True);
  end;
  CloseStreams;
  if (ErrorText = '') and not Cancelled then
    FinalizeOutputFile
  else
  begin
    CleanupOutputFile;
    if not Cancelled then
      ShowErrorDialog(ErrorText,DiagnosticDetails);
  end;
  FTask := nil;
  // The error dialog above has returned: acknowledgement clears the shell
  // indicator while the inline error remains available for inspection.
  ClearTaskbarProgress;
  TInterlocked.Exchange(FCancelRequested, 0);
  SetInlineStatus(StatusText, (ErrorText <> '') and not Cancelled, DetailsText);
  if DiagnosticsText <> '' then
    FStatsLabel.Hint := DetailsText + DiagnosticsText;
  SetBusy(False);
end;

function IsCancellationException(const Error: Exception): Boolean;
var
  I: Integer;
  Aggregate: EAggregateException;
begin
  if Error is ELzmaCancelled then
    Exit(True);
  if not (Error is EAggregateException) then
    Exit(False);
  Aggregate := EAggregateException(Error);
  if Aggregate.Count = 0 then
    Exit(False);
  for I := 0 to Aggregate.Count - 1 do
    if not IsCancellationException(Aggregate.InnerExceptions[I]) then
      Exit(False);
  Result := True;
end;

procedure TMainForm.PollTimerTimer(Sender: TObject);
var
  ErrorText: string;
  Failure:TGuiFailure;
  Cancelled: Boolean;
begin
  if FTask = nil then
    Exit;
  UpdateProgressUi(TInterlocked.Read(FLastIn), TInterlocked.Read(FLastOut));
  case FTask.Status of
    TTaskStatus.Completed:
      FinishTask('', TInterlocked.CompareExchange(FCancelRequested, 0, 0) <> 0);
    TTaskStatus.Canceled:
      FinishTask('', True);
    TTaskStatus.Exception:
      begin
        ErrorText := TextOf('Task failed');
        Failure.Details:='';
        Cancelled := False;
        try
          FTask.Wait;
        except
          on E: Exception do
            if IsCancellationException(E) then
            begin
              Cancelled := True;
              ErrorText := '';
            end
            else
            begin
              Failure:=DescribeGuiFailure(E,Ord(FLanguage));
              ErrorText:=Failure.Summary;
            end;
        end;
        FinishTask(ErrorText, Cancelled,Failure.Details);
      end;
  end;
end;

{$I Lzma2BenchmarkMethods.inc}
{$I Lzma2GuiLayoutQA.inc}

initialization
  DictionaryMbValues:=GuiChoices('dictionaryMiB');
  var SupportedDictionaries:=TList<Integer>.Create;
  try
    for var MiB in GuiChoices('benchmarkDictionaryMiB') do
      if (MiB>0) and ((UInt64(MiB) shl 20)<=TLzmaBenchmark.MaximumDictionarySize) then
        SupportedDictionaries.Add(MiB);
    BenchmarkDictionaryMb:=SupportedDictionaries.ToArray;
  finally SupportedDictionaries.Free;end;
  if Length(BenchmarkDictionaryMb)=0 then
    raise EConvertError.Create('No supported benchmark dictionaries in GUI catalog');
  BenchmarkPassCounts:=GuiChoices('benchmarkPasses');
  if GuiLanguageCount<>Ord(High(TGuiLanguage))+1 then
    raise EConvertError.Create('GUI language metadata does not match the supported language set');
  for var Language:=Low(TGuiLanguage) to High(TGuiLanguage) do
  begin
    GuiLanguageCodes[Language]:=GuiLanguageCode(Ord(Language));
    GuiLanguageNames[Language]:=GuiLanguageName(Ord(Language));
  end;
end.
