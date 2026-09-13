; cpcv's per-user Windows setup wizard. The build script compiles this only
; from a clean git-archive staging directory and provides the four defines.

#ifndef CpcvVersion
  #error CpcvVersion must be supplied by build-windows.ps1.
#endif
#ifndef CpcvSourceRoot
  #error CpcvSourceRoot must be supplied by build-windows.ps1.
#endif
#ifndef CpcvOutputDir
  #error CpcvOutputDir must be supplied by build-windows.ps1.
#endif
#ifndef CpcvOutputBaseName
  #error CpcvOutputBaseName must be supplied by build-windows.ps1.
#endif

[Setup]
AppId={{50B6B052-0B5A-4F76-91B1-2E9B9C59B3D4}
AppName=cpcv
AppVersion={#CpcvVersion}
AppPublisher=cpcv contributors
AppPublisherURL=https://github.com/thapecroth/cpcv
AppSupportURL=https://github.com/thapecroth/cpcv/issues
AppUpdatesURL=https://github.com/thapecroth/cpcv/releases
DefaultDirName={localappdata}\Programs\cpcv
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#CpcvOutputDir}
OutputBaseFilename={#CpcvOutputBaseName}
SetupIconFile={#CpcvSourceRoot}\assets\windows\cpcv-tray.ico
UninstallDisplayIcon={app}\assets\windows\cpcv-tray.ico
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
VersionInfoVersion={#CpcvVersion}.0
VersionInfoProductVersion={#CpcvVersion}.0
ChangesEnvironment=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "remotetmux"; Description: "Install the optional cpcv tmux plugin on my SSH computer (verified after setup)"; Flags: unchecked
Name: "desktopupload"; Description: "Add an Upload Clipboard Image shortcut to my desktop"; Flags: unchecked

[Files]
; The source directory is a clean committed-tree export. These excludes are a
; second boundary in case packaging files are added later.
Source: "{#CpcvSourceRoot}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: ".git\*,build\*,cache\*,*.log,*.tmp,cpcv.config.psd1,config.psd1"

[Icons]
Name: "{autodesktop}\Upload Clipboard Image with cpcv"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -STA -ExecutionPolicy RemoteSigned -File ""{app}\cpcv-now.ps1"""; WorkingDir: "{app}"; Tasks: desktopupload

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy RemoteSigned -File ""{app}\uninstall-tray.ps1"" -Confirm:$false"; WorkingDir: "{app}"; Flags: runhidden waituntilterminated; RunOnceId: "cpcv-tray-uninstall"
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy RemoteSigned -File ""{app}\uninstall-autostart.ps1"" -Confirm:$false"; WorkingDir: "{app}"; Flags: runhidden waituntilterminated; RunOnceId: "cpcv-autostart-uninstall"

[Code]
var
  ConnectionPage: TInputQueryWizardPage;
  ExistingConnectionPage: TOutputMsgWizardPage;
  StatusPage: TOutputMsgMemoWizardPage;
  BootstrapProgressPage: TOutputMarqueeProgressWizardPage;
  OnboardingPageID: Integer;
  ExistingConfiguration: Boolean;
  BootstrapSucceeded: Boolean;
  StatusFile: String;

function IsAsciiAlphaNumeric(Value: Char): Boolean;
begin
  Result := ((Value >= 'A') and (Value <= 'Z')) or
            ((Value >= 'a') and (Value <= 'z')) or
            ((Value >= '0') and (Value <= '9'));
end;

function IsSafeHostAlias(Value: String): Boolean;
var
  Index: Integer;
  Character: Char;
begin
  Result := False;
  Value := Trim(Value);
  if (Length(Value) = 0) or (not IsAsciiAlphaNumeric(Value[1])) then
    Exit;

  for Index := 1 to Length(Value) do begin
    Character := Value[Index];
    if not (IsAsciiAlphaNumeric(Character) or (Character = '.') or
            (Character = '_') or (Character = '@') or (Character = '-') or
            (Character = ':')) then
      Exit;
  end;
  Result := True;
end;

function HasParentSegment(Value: String): Boolean;
begin
  Result := (Value = '..') or (Pos('../', Value) = 1) or
            (Pos('/../', Value) > 0) or
            ((Length(Value) >= 3) and (Copy(Value, Length(Value) - 2, 3) = '/..'));
end;

function IsSafeRemoteDir(Value: String): Boolean;
var
  Index: Integer;
  Character: Char;
begin
  Result := False;
  Value := Trim(Value);
  if (Length(Value) = 0) or (not IsAsciiAlphaNumeric(Value[1])) or HasParentSegment(Value) then
    Exit;

  for Index := 1 to Length(Value) do begin
    Character := Value[Index];
    if not (IsAsciiAlphaNumeric(Character) or (Character = '.') or
            (Character = '_') or (Character = '-') or (Character = '/')) then
      Exit;
  end;
  Result := True;
end;

procedure InitializeWizard;
begin
  ExistingConfiguration := FileExists(ExpandConstant('{localappdata}\cpcv\config.psd1')) or
                           (GetEnv('CPCV_CONFIG') <> '');
  BootstrapSucceeded := False;
  StatusFile := ExpandConstant('{tmp}\cpcv-install-status.ini');
  BootstrapProgressPage := CreateOutputMarqueeProgressPage(
    'Connecting cpcv', 'Starting the local service and checking your SSH computer.');

  if not ExistingConfiguration then begin
    ConnectionPage := CreateInputQueryPage(wpInstalling,
      'Connect cpcv', 'Name the SSH computer you want cpcv to use',
      'Enter the connection name that works with ssh <name> (for example, devbox or me@devbox). ' +
      'Use an SSH config alias for a custom port or proxy. Do not enter a password or private key.');
    ConnectionPage.Add('SSH connection name:', False);
    ConnectionPage.Values[0] := '';
    ConnectionPage.Add('Remote image folder:', False);
    ConnectionPage.Values[1] := 'clipboard-images';
    OnboardingPageID := ConnectionPage.ID;
  end
  else begin
    ExistingConnectionPage := CreateOutputMsgPage(wpInstalling,
      'Connect cpcv', 'Your existing SSH computer is preserved',
      'Setup will keep your private cpcv connection settings, start the local uploader, and check the configured SSH computer. ' +
      'Use cpcv Settings after setup if you want to choose a different computer.');
    OnboardingPageID := ExistingConnectionPage.ID;
  end;

  StatusPage := CreateOutputMsgMemoPage(OnboardingPageID,
    'cpcv setup status', 'Connection and tmux readiness',
    'Setup will show the local service, SSH, tmux, and plugin status here.', 'Waiting for setup to run.');
  StatusPage.RichEditViewer.ReadOnly := True;
  StatusPage.RichEditViewer.WordWrap := True;
  StatusPage.RichEditViewer.ScrollBars := ssVertical;
end;

function StartCpcv: Boolean; forward;
procedure UpdateStatusPage; forward;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  HostAlias: String;
  RemoteDir: String;
begin
  Result := True;
  if (not ExistingConfiguration) and (CurPageID = ConnectionPage.ID) then begin
    HostAlias := Trim(ConnectionPage.Values[0]);
    RemoteDir := Trim(ConnectionPage.Values[1]);
    if not IsSafeHostAlias(HostAlias) then begin
      MsgBox('Enter a valid SSH connection name: an alias, hostname, or user@host. It cannot contain spaces, quotes, or shell syntax.', mbError, MB_OK);
      Result := False;
      Exit;
    end;
    if not IsSafeRemoteDir(RemoteDir) then begin
      MsgBox('Enter a relative remote folder without parent traversal (for example: clipboard-images).', mbError, MB_OK);
      Result := False;
      Exit;
    end;
  end;

  if CurPageID = OnboardingPageID then begin
    BootstrapSucceeded := StartCpcv;
    UpdateStatusPage;
  end;
end;

function BootstrapParameters: String;
begin
  Result := '-NoProfile -ExecutionPolicy RemoteSigned -File "' +
    ExpandConstant('{app}\windows\installer\cpcv-installer.ps1') + '"';
  Result := Result + ' -StatusFile "' + StatusFile + '"';
  if not ExistingConfiguration then begin
    Result := Result + ' -HostAlias "' + Trim(ConnectionPage.Values[0]) + '"';
    Result := Result + ' -RemoteDir "' + Trim(ConnectionPage.Values[1]) + '"';
  end;
  if WizardIsTaskSelected('remotetmux') then
    Result := Result + ' -DeployRemoteHelpers';
end;

function StartCpcv: Boolean;
var
  ExitCode: Integer;
begin
  DeleteFile(StatusFile);
  if not WizardSilent then begin
    BootstrapProgressPage.SetText('Connecting cpcv',
      'Starting the local service and checking your SSH computer. This can take a few seconds.');
    BootstrapProgressPage.Show;
  end;
  try
    Result := Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
      BootstrapParameters, ExpandConstant('{app}'), SW_HIDE,
      ewWaitUntilTerminated, ExitCode) and (ExitCode = 0);
  finally
    if not WizardSilent then
      BootstrapProgressPage.Hide;
  end;
end;

function ReadCpcvStatusValue(const Key, Default: String): String;
begin
  if not FileExists(StatusFile) then begin
    Result := Default;
    Exit;
  end;
  Result := GetIniString('cpcv', Key, Default, StatusFile);
end;

function ReadCpcvStatusHost: String;
var
  Value: String;
begin
  Value := ReadCpcvStatusValue('HostAlias', 'configured SSH computer');
  if IsSafeHostAlias(Value) then
    Result := Value
  else
    Result := 'configured SSH computer';
end;

function BuildCpcvStatusText: String;
var
  InstallResult: String;
  Failure: String;
  ConfigState: String;
  HostAlias: String;
  RemoteDir: String;
  LocalWatcher: String;
  Tray: String;
  SshConnection: String;
  RemoteTmux: String;
  TmuxPlugin: String;
  NewLine: String;
begin
  NewLine := #13#10;
  if not FileExists(StatusFile) then begin
    Result := 'cpcv could not read its setup summary.' + NewLine + NewLine +
      'The program files were copied, but the local service did not report a status. ' +
      'Confirm that PowerShell, ssh.exe, and scp.exe are available, then run Setup again.';
    Exit;
  end;

  InstallResult := ReadCpcvStatusValue('Result', 'Needs attention');
  Failure := ReadCpcvStatusValue('Failure', '');
  ConfigState := ReadCpcvStatusValue('Configuration', 'Not checked');
  HostAlias := ReadCpcvStatusHost;
  RemoteDir := ReadCpcvStatusValue('RemoteDir', 'clipboard-images');
  LocalWatcher := ReadCpcvStatusValue('LocalWatcher', 'Not started');
  Tray := ReadCpcvStatusValue('Tray', 'Not started');
  SshConnection := ReadCpcvStatusValue('SshConnection', 'Not checked');
  RemoteTmux := ReadCpcvStatusValue('RemoteTmux', 'Not checked');
  TmuxPlugin := ReadCpcvStatusValue('TmuxPlugin', 'Not checked');

  Result := 'Installation status' + NewLine + NewLine +
    'Local watcher: ' + LocalWatcher + NewLine +
    'Tray status app: ' + Tray + NewLine +
    'Configuration: ' + ConfigState + NewLine +
    'SSH computer: ' + HostAlias + NewLine +
    'SSH check: ' + SshConnection + NewLine +
    'tmux on SSH computer: ' + RemoteTmux + NewLine +
    'cpcv tmux plugin: ' + TmuxPlugin + NewLine;

  if InstallResult <> 'Installed' then begin
    Result := Result + NewLine + 'What needs attention' + NewLine +
      Failure + NewLine +
      'Use Back to correct the connection name or rerun Setup after fixing local prerequisites.';
    Exit;
  end;

  if SshConnection <> 'Connected' then begin
    Result := Result + NewLine + 'Next step' + NewLine +
      'Finish SSH setup for ' + HostAlias + ' so ssh can connect without a password prompt or host-key question. ' +
      'Then rerun Setup or restart cpcv from the tray. Automatic uploads will use this SSH connection.';
    Exit;
  end;

  Result := Result + NewLine + 'Next step' + NewLine +
    'Copy an image locally. cpcv will upload it to $HOME/' + RemoteDir + '/latest.png on ' + HostAlias + '.';
  if RemoteTmux = 'Not installed' then begin
    Result := Result + NewLine + NewLine +
      'Automatic image uploads are ready. Install tmux later if you want pane-specific Ctrl-V paste.';
    if TmuxPlugin = 'Installed by Setup' then
      Result := Result + NewLine + 'The plugin files are already on the SSH computer and will be ready after tmux is installed.';
  end
  else if RemoteTmux = 'Installed' then begin
    if (TmuxPlugin = 'Installed by Setup') or (TmuxPlugin = 'Already installed') then begin
      Result := Result + NewLine + NewLine +
        'To enable pane-specific Ctrl-V, add this line to the remote ~/.tmux.conf:' + NewLine +
        'run-shell ~/.local/lib/cpcv/tmux/cpcv.tmux' + NewLine +
        'Then reload tmux. Setup installs plugin files but never edits your tmux configuration.';
    end
    else begin
      Result := Result + NewLine + NewLine +
        'tmux is available. Rerun Setup and select the optional tmux plugin if you want pane-specific Ctrl-V paste.';
    end;
  end
  else if (TmuxPlugin = 'Installed by Setup') or (TmuxPlugin = 'Already installed') then begin
    Result := Result + NewLine + NewLine +
      'The tmux plugin files are present, but cpcv could not determine tmux readiness. Check the SSH computer, then add the documented run-shell line when tmux is available.';
  end;
end;

procedure UpdateStatusPage;
begin
  StatusPage.RichEditViewer.Lines.Text := BuildCpcvStatusText;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if (CurStep = ssPostInstall) and WizardSilent then begin
    BootstrapSucceeded := StartCpcv;
  end;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if CurPageID = StatusPage.ID then
    UpdateStatusPage;
  if CurPageID = wpFinished then begin
    if BootstrapSucceeded then begin
      WizardForm.FinishedHeadingLabel.Caption := 'cpcv is ready';
      WizardForm.FinishedLabel.Caption := 'Your setup summary shows the SSH, tmux, and plugin status. You can open the cpcv tray icon at any time to check uploads.';
    end
    else begin
      WizardForm.FinishedHeadingLabel.Caption := 'cpcv needs attention';
      WizardForm.FinishedLabel.Caption := 'cpcv files were copied, but its local service did not finish starting. Review the setup status, correct the issue, and run Setup again.';
    end;
  end;
end;
