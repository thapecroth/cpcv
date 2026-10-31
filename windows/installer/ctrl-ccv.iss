; ctrl-ccv's per-user Windows setup wizard. The build script compiles this only
; from a clean git-archive staging directory and provides the four defines.

#ifndef CtrlCcvVersion
  #error CtrlCcvVersion must be supplied by build-windows.ps1.
#endif
#ifndef CtrlCcvSourceRoot
  #error CtrlCcvSourceRoot must be supplied by build-windows.ps1.
#endif
#ifndef CtrlCcvOutputDir
  #error CtrlCcvOutputDir must be supplied by build-windows.ps1.
#endif
#ifndef CtrlCcvOutputBaseName
  #error CtrlCcvOutputBaseName must be supplied by build-windows.ps1.
#endif

[Setup]
AppId={{50B6B052-0B5A-4F76-91B1-2E9B9C59B3D4}
AppName=ctrl-ccv
AppVersion={#CtrlCcvVersion}
AppPublisher=ctrl-ccv contributors
AppPublisherURL=https://github.com/thapecroth/ctrl-ccv
AppSupportURL=https://github.com/thapecroth/ctrl-ccv/issues
AppUpdatesURL=https://github.com/thapecroth/ctrl-ccv/releases
DefaultDirName={localappdata}\Programs\ctrl-ccv
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#CtrlCcvOutputDir}
OutputBaseFilename={#CtrlCcvOutputBaseName}
SetupIconFile={#CtrlCcvSourceRoot}\assets\windows\ctrl-ccv-tray.ico
UninstallDisplayIcon={app}\assets\windows\ctrl-ccv-tray.ico
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
VersionInfoVersion={#CtrlCcvVersion}.0
VersionInfoProductVersion={#CtrlCcvVersion}.0
ChangesEnvironment=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "remotetmux"; Description: "Install the optional ctrl-ccv tmux plugin on my SSH computer (verified after setup)"; Flags: unchecked
Name: "desktopupload"; Description: "Add an Upload Clipboard Image shortcut to my desktop"; Flags: unchecked

[Files]
; The source directory is a clean committed-tree export. These excludes are a
; second boundary in case packaging files are added later.
Source: "{#CtrlCcvSourceRoot}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: ".git\*,build\*,cache\*,*.log,*.tmp,ctrl-ccv.config.psd1,config.psd1"

[Icons]
Name: "{autodesktop}\Upload Clipboard Image with ctrl-ccv"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -STA -ExecutionPolicy RemoteSigned -File ""{app}\ctrl-ccv-now.ps1"""; WorkingDir: "{app}"; Tasks: desktopupload

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy RemoteSigned -File ""{app}\uninstall-tray.ps1"" -Confirm:$false"; WorkingDir: "{app}"; Flags: runhidden waituntilterminated; RunOnceId: "ctrl-ccv-tray-uninstall"
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy RemoteSigned -File ""{app}\uninstall-autostart.ps1"" -Confirm:$false"; WorkingDir: "{app}"; Flags: runhidden waituntilterminated; RunOnceId: "ctrl-ccv-autostart-uninstall"

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
  ExistingConfiguration := FileExists(ExpandConstant('{localappdata}\ctrl-ccv\config.psd1')) or
                           (GetEnv('CTRL_CCV_CONFIG') <> '');
  BootstrapSucceeded := False;
  StatusFile := ExpandConstant('{tmp}\ctrl-ccv-install-status.ini');
  BootstrapProgressPage := CreateOutputMarqueeProgressPage(
    'Connecting ctrl-ccv', 'Starting the local service and checking your SSH computer.');

  if not ExistingConfiguration then begin
    ConnectionPage := CreateInputQueryPage(wpInstalling,
      'Connect ctrl-ccv', 'Name the SSH computer you want ctrl-ccv to use',
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
      'Connect ctrl-ccv', 'Your existing SSH computer is preserved',
      'Setup will keep your private ctrl-ccv connection settings, start the local uploader, and check the configured SSH computer. ' +
      'Use ctrl-ccv Settings after setup if you want to choose a different computer.');
    OnboardingPageID := ExistingConnectionPage.ID;
  end;

  StatusPage := CreateOutputMsgMemoPage(OnboardingPageID,
    'ctrl-ccv setup status', 'Connection and tmux readiness',
    'Setup will show the local service, SSH, tmux, and plugin status here.', 'Waiting for setup to run.');
  StatusPage.RichEditViewer.ReadOnly := True;
  StatusPage.RichEditViewer.WordWrap := True;
  StatusPage.RichEditViewer.ScrollBars := ssVertical;
end;

function StartCtrlCcv: Boolean; forward;
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
    BootstrapSucceeded := StartCtrlCcv;
    UpdateStatusPage;
  end;
end;

function BootstrapParameters: String;
begin
  Result := '-NoProfile -ExecutionPolicy RemoteSigned -File "' +
    ExpandConstant('{app}\windows\installer\ctrl-ccv-installer.ps1') + '"';
  Result := Result + ' -StatusFile "' + StatusFile + '"';
  if not ExistingConfiguration then begin
    Result := Result + ' -HostAlias "' + Trim(ConnectionPage.Values[0]) + '"';
    Result := Result + ' -RemoteDir "' + Trim(ConnectionPage.Values[1]) + '"';
  end;
  if WizardIsTaskSelected('remotetmux') then
    Result := Result + ' -DeployRemoteHelpers';
end;

function StartCtrlCcv: Boolean;
var
  ExitCode: Integer;
begin
  DeleteFile(StatusFile);
  if not WizardSilent then begin
    BootstrapProgressPage.SetText('Connecting ctrl-ccv',
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

function ReadCtrlCcvStatusValue(const Key, Default: String): String;
begin
  if not FileExists(StatusFile) then begin
    Result := Default;
    Exit;
  end;
  Result := GetIniString('ctrl-ccv', Key, Default, StatusFile);
end;

function ReadCtrlCcvStatusHost: String;
var
  Value: String;
begin
  Value := ReadCtrlCcvStatusValue('HostAlias', 'configured SSH computer');
  if IsSafeHostAlias(Value) then
    Result := Value
  else
    Result := 'configured SSH computer';
end;

function BuildCtrlCcvStatusText: String;
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
    Result := 'ctrl-ccv could not read its setup summary.' + NewLine + NewLine +
      'The program files were copied, but the local service did not report a status. ' +
      'Confirm that PowerShell, ssh.exe, and scp.exe are available, then run Setup again.';
    Exit;
  end;

  InstallResult := ReadCtrlCcvStatusValue('Result', 'Needs attention');
  Failure := ReadCtrlCcvStatusValue('Failure', '');
  ConfigState := ReadCtrlCcvStatusValue('Configuration', 'Not checked');
  HostAlias := ReadCtrlCcvStatusHost;
  RemoteDir := ReadCtrlCcvStatusValue('RemoteDir', 'clipboard-images');
  LocalWatcher := ReadCtrlCcvStatusValue('LocalWatcher', 'Not started');
  Tray := ReadCtrlCcvStatusValue('Tray', 'Not started');
  SshConnection := ReadCtrlCcvStatusValue('SshConnection', 'Not checked');
  RemoteTmux := ReadCtrlCcvStatusValue('RemoteTmux', 'Not checked');
  TmuxPlugin := ReadCtrlCcvStatusValue('TmuxPlugin', 'Not checked');

  Result := 'Installation status' + NewLine + NewLine +
    'Local watcher: ' + LocalWatcher + NewLine +
    'Tray status app: ' + Tray + NewLine +
    'Configuration: ' + ConfigState + NewLine +
    'SSH computer: ' + HostAlias + NewLine +
    'SSH check: ' + SshConnection + NewLine +
    'tmux on SSH computer: ' + RemoteTmux + NewLine +
    'ctrl-ccv tmux plugin: ' + TmuxPlugin + NewLine;

  if InstallResult <> 'Installed' then begin
    Result := Result + NewLine + 'What needs attention' + NewLine +
      Failure + NewLine +
      'Use Back to correct the connection name or rerun Setup after fixing local prerequisites.';
    Exit;
  end;

  if SshConnection <> 'Connected' then begin
    Result := Result + NewLine + 'Next step' + NewLine +
      'Finish SSH setup for ' + HostAlias + ' so ssh can connect without a password prompt or host-key question. ' +
      'Then rerun Setup or restart ctrl-ccv from the tray. Automatic uploads will use this SSH connection.';
    Exit;
  end;

  Result := Result + NewLine + 'Next step' + NewLine +
    'Copy an image locally. ctrl-ccv will upload it to $HOME/' + RemoteDir + '/latest.png on ' + HostAlias + '.';
  if RemoteTmux = 'Not installed' then begin
    Result := Result + NewLine + NewLine +
      'Automatic image uploads are ready. Install tmux later if you want pane-specific path insertion.';
    if TmuxPlugin = 'Installed by Setup' then
      Result := Result + NewLine + 'The plugin files are already on the SSH computer and will be ready after tmux is installed.';
  end
  else if RemoteTmux = 'Installed' then begin
    if (TmuxPlugin = 'Installed by Setup') or (TmuxPlugin = 'Already installed') then begin
      Result := Result + NewLine + NewLine +
        'To enable pane-specific path insertion, add this line to the remote ~/.tmux.conf:' + NewLine +
        'run-shell ~/.local/lib/ctrl-ccv/tmux/ctrl-ccv.tmux' + NewLine +
        'Then reload tmux. Use Configure tmux path insertion in the ctrl-ccv tray to choose a shortcut; its default pairs Windows Alt-V with macOS Ctrl-V. Setup installs plugin files but never edits your tmux configuration.';
    end
    else begin
      Result := Result + NewLine + NewLine +
        'tmux is available. Rerun Setup and select the optional tmux plugin if you want pane-specific path insertion.';
    end;
  end
  else if (TmuxPlugin = 'Installed by Setup') or (TmuxPlugin = 'Already installed') then begin
    Result := Result + NewLine + NewLine +
      'The tmux plugin files are present, but ctrl-ccv could not determine tmux readiness. Check the SSH computer, then add the documented run-shell line when tmux is available.';
  end;
end;

procedure UpdateStatusPage;
begin
  StatusPage.RichEditViewer.Lines.Text := BuildCtrlCcvStatusText;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if (CurStep = ssPostInstall) and WizardSilent then begin
    BootstrapSucceeded := StartCtrlCcv;
  end;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if CurPageID = StatusPage.ID then
    UpdateStatusPage;
  if CurPageID = wpFinished then begin
    if BootstrapSucceeded then begin
      WizardForm.FinishedHeadingLabel.Caption := 'ctrl-ccv is ready';
      WizardForm.FinishedLabel.Caption := 'Your setup summary shows the SSH, tmux, and plugin status. You can open the ctrl-ccv tray icon at any time to check uploads.';
    end
    else begin
      WizardForm.FinishedHeadingLabel.Caption := 'ctrl-ccv needs attention';
      WizardForm.FinishedLabel.Caption := 'ctrl-ccv files were copied, but its local service did not finish starting. Review the setup status, correct the issue, and run Setup again.';
    end;
  end;
end;
