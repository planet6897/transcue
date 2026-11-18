; Transcue Windows 설치본 (Inno Setup 6.1+)
; scripts/release.ps1이 빌드한 Release 폴더로 transcue-X.Y.Z-windows-x64-setup.exe를 만든다.
;   ISCC.exe /DAppVersion=X.Y.Z /DSourceDir=<Release 폴더> /DOutputDir=<dist> scripts\windows-installer.iss
;
; - 관리자 권한 없이 사용자 폴더(%LOCALAPPDATA%\Programs\Transcue)에 설치한다.
;   앱 안 업데이트(app/lib/src/update/updater.dart)가 앱 폴더에 새 파일을 덮어쓰므로 쓸 수 있는 곳이어야 한다.
; - yt-dlp를 찾지 못하면 GitHub에서 받아 %LOCALAPPDATA%\Programs\yt-dlp에 둔다
;   (앱이 이 폴더를 찾아본다: app/lib/src/pipeline/tools.dart windowsToolDirs).

#ifndef AppVersion
  #error "/DAppVersion=X.Y.Z 가 필요합니다"
#endif
#ifndef SourceDir
  #error "/DSourceDir=<flutter build windows의 Release 폴더> 가 필요합니다"
#endif
#ifndef OutputDir
  #define OutputDir "."
#endif

#define YtDlpUrl "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe"

[Setup]
; AppId는 바꾸지 않는다 (바꾸면 업그레이드 대신 따로 설치된다)
AppId={{6A1F3C52-8E0B-4C7D-9B2A-5E4F1D7C3B90}
AppName=Transcue
AppVersion={#AppVersion}
AppVerName=Transcue {#AppVersion}
AppPublisher=Transcue
AppPublisherURL=https://github.com/planet6897/transcue
AppSupportURL=https://github.com/planet6897/transcue/issues
AppUpdatesURL=https://github.com/planet6897/transcue/releases
VersionInfoVersion={#AppVersion}
DefaultDirName={autopf}\Transcue
DefaultGroupName=Transcue
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#OutputDir}
OutputBaseFilename=transcue-{#AppVersion}-windows-x64-setup
SetupIconFile=..\app\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\transcue.exe
UninstallDisplayName=Transcue
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "korean"; MessagesFile: "compiler:Languages\Korean.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[CustomMessages]
korean.DesktopIcon=바탕 화면에 바로 가기 만들기
english.DesktopIcon=Create a desktop shortcut
korean.YtDlp=yt-dlp 설치 (YouTube 영상 재생에 필요, 없을 때만)
english.YtDlp=Install yt-dlp (needed for YouTube videos; only if missing)
korean.ToolsGroup=외부 도구:
english.ToolsGroup=External tools:
korean.YtDlpFailed=yt-dlp를 받지 못했습니다. YouTube 영상을 열려면 나중에 직접 설치하세요 (winget install yt-dlp.yt-dlp).%n%n%1
english.YtDlpFailed=Could not download yt-dlp. Install it later to open YouTube videos (winget install yt-dlp.yt-dlp).%n%n%1
korean.Launch=Transcue 실행
english.Launch=Launch Transcue

[Tasks]
Name: "desktopicon"; Description: "{cm:DesktopIcon}"; Flags: unchecked
Name: "ytdlp"; Description: "{cm:YtDlp}"; GroupDescription: "{cm:ToolsGroup}"; Check: YtDlpMissing

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Transcue"; Filename: "{app}\transcue.exe"
Name: "{autodesktop}\Transcue"; Filename: "{app}\transcue.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\transcue.exe"; Description: "{cm:Launch}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; 앱 안 업데이트가 덮어쓰며 더한 파일 (설치 목록에 없어 그냥은 남는다).
; 사용자가 고른 폴더일 수 있으므로 {app} 전체가 아니라 Flutter 빌드 모양의 파일만 지운다.
Type: filesandordirs; Name: "{app}\data"
Type: files; Name: "{app}\*.dll"
Type: files; Name: "{app}\*.exe"
Type: dirifempty; Name: "{app}"

[Code]
var
  DownloadPage: TDownloadWizardPage;

function YtDlpDir: String;
begin
  Result := ExpandConstant('{localappdata}\Programs\yt-dlp');
end;

{ 앱이 yt-dlp를 찾는 곳(tools.dart의 windowsToolDirs와 PATH)에 이미 있는지 }
function YtDlpMissing: Boolean;
var
  Dirs: String;
begin
  Dirs := YtDlpDir + ';' +
    ExpandConstant('{localappdata}\Microsoft\WinGet\Links') + ';' +
    ExpandConstant('{commonpf64}\WinGet\Links') + ';' +
    GetEnv('USERPROFILE') + '\scoop\shims;' +
    GetEnv('ProgramData') + '\chocolatey\bin;' +
    GetEnv('PATH');
  Result := FileSearch('yt-dlp.exe', Dirs) = '';
end;

procedure InitializeWizard;
begin
  DownloadPage := CreateDownloadPage(SetupMessage(msgWizardPreparing), SetupMessage(msgPreparingDesc), nil);
end;

procedure InstallYtDlp(const Downloaded: String);
begin
  ForceDirectories(YtDlpDir);
  if not FileCopy(Downloaded, YtDlpDir + '\yt-dlp.exe', False) then
    RaiseException('copy to ' + YtDlpDir + ' failed');
end;

procedure YtDlpFailed;
begin
  Log('yt-dlp: ' + GetExceptionMessage);
  SuppressibleMsgBox(FmtMessage(CustomMessage('YtDlpFailed'), [GetExceptionMessage]), mbError, MB_OK, IDOK);
end;

{ 파일을 복사하기 전에 받는다. 실패해도 설치는 계속한다.
  /SILENT·/VERYSILENT에서도 건너뛴 페이지마다 불리므로 여기 한 곳에서만 받는다. }
function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if (CurPageID = wpReady) and WizardIsTaskSelected('ytdlp') then
  begin
    DownloadPage.Clear;
    DownloadPage.Add('{#YtDlpUrl}', 'yt-dlp.exe', '');
    DownloadPage.Show;
    try
      try
        DownloadPage.Download;
        InstallYtDlp(ExpandConstant('{tmp}\yt-dlp.exe'));
      except
        YtDlpFailed;
      end;
    finally
      DownloadPage.Hide;
    end;
  end;
end;
