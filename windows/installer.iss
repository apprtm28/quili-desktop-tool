; Version comes from ../VERSION: iscc /DAppVersion=$(cat ../VERSION) installer.iss
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif

[Setup]
SetupIconFile=assets\app.ico
UninstallDisplayIcon={app}\Quili.exe
AppName=Quili
AppVersion={#AppVersion}
DefaultDirName={autopf}\Quili
DefaultGroupName=Quili
OutputDir=..\dist\windows
OutputBaseFilename=QuiliSetup-{#AppVersion}
PrivilegesRequired=lowest
ArchitecturesInstallIn64BitMode=x64compatible
Compression=lzma2

[Files]
Source: "..\dist\windows\Quili.exe"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\Quili"; Filename: "{app}\Quili.exe"

[Run]
Filename: "{app}\Quili.exe"; Description: "Launch Quili"; Flags: nowait postinstall skipifsilent
