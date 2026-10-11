#ifndef AppVersion
  #error AppVersion must be supplied by package_windows.ps1
#endif

[Setup]
AppId={{BAF41EB0-25E9-44C7-AE5D-27C7B064F68B}
AppName=Echoes
AppVersion={#AppVersion}
AppPublisher=Echoes Project
AppPublisherURL=https://github.com/Ericwyn/echoes
DefaultDirName={localappdata}\Programs\Echoes
DefaultGroupName=Echoes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#PackageOutputDir}
OutputBaseFilename={#PackageBaseName}-setup
SetupIconFile={#AppIcon}
UninstallDisplayIcon={app}\echoes.exe
VersionInfoVersion={#WindowsVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
DisableProgramGroupPage=yes
CloseApplications=yes
RestartApplications=no

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#BundleDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Echoes"; Filename: "{app}\echoes.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\Echoes"; Filename: "{app}\echoes.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\echoes.exe"; Description: "{cm:LaunchProgram,Echoes}"; Flags: nowait postinstall skipifsilent
