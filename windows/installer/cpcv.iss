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
Name: "remotetmux"; Description: "Install optional cpcv tmux helpers on my SSH host"; Flags: unchecked
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
  ExistingConfiguration: Boolean;
  BootstrapSucceeded: Boolean;

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

  if not ExistingConfiguration then begin
    ConnectionPage := CreateInputQueryPage(wpWelcome,
      'Connect cpcv', 'Use your existing SSH setup',
      'cpcv uploads copied images through your existing SSH configuration. ' +
      'Enter an SSH alias, hostname, or user@host. Do not enter a password or private key here.');
    ConnectionPage.Add('SSH alias or host:', False);
    ConnectionPage.Values[0] := '';
    ConnectionPage.Add('Remote image folder:', False);
    ConnectionPage.Values[1] := 'clipboard-images';
  end;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  HostAlias: String;
  RemoteDir: String;
begin
  Result := True;
  if ExistingConfiguration then
    Exit;
  if CurPageID <> ConnectionPage.ID then
    Exit;

  HostAlias := Trim(ConnectionPage.Values[0]);
  RemoteDir := Trim(ConnectionPage.Values[1]);
  if not IsSafeHostAlias(HostAlias) then begin
    MsgBox('Enter a valid SSH alias, hostname, or user@host. It cannot contain spaces, quotes, or shell syntax.', mbError, MB_OK);
    Result := False;
    Exit;
  end;
  if not IsSafeRemoteDir(RemoteDir) then begin
    MsgBox('Enter a relative remote folder without parent traversal (for example: clipboard-images).', mbError, MB_OK);
    Result := False;
  end;
end;

function BootstrapParameters: String;
begin
  Result := '-NoProfile -ExecutionPolicy RemoteSigned -File "' +
    ExpandConstant('{app}\windows\installer\cpcv-installer.ps1') + '"';
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
  Result := Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
    BootstrapParameters, ExpandConstant('{app}'), SW_HIDE,
    ewWaitUntilTerminated, ExitCode) and (ExitCode = 0);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then begin
    BootstrapSucceeded := StartCpcv;
    if not BootstrapSucceeded then
      MsgBox('cpcv files were installed, but the local service could not be started. ' +
        'Your private configuration was not removed. Confirm that PowerShell, ssh.exe, and scp.exe are available, then run the installer again or use the included PowerShell installers.',
        mbError, MB_OK);
  end;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if (CurPageID = wpFinished) and (not BootstrapSucceeded) then
    WizardForm.FinishedLabel.Caption := 'cpcv was copied, but needs attention before it can start. Review the message shown by Setup, then rerun Setup after correcting the prerequisite.';
end;
