[Setup]
AppName=Paraphrase Tool
AppVersion=1.0.0
DefaultDirName={autopf}\ParaphraseTool
DefaultGroupName=Paraphrase Tool
OutputDir=dist
OutputBaseFilename=ParaphraseToolSetup
PrivilegesRequired=lowest
ArchitecturesInstallIn64BitMode=x64compatible
Compression=lzma2

[Files]
Source: "dist\ParaphraseTool.exe"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\Paraphrase Tool"; Filename: "{app}\ParaphraseTool.exe"

[Run]
Filename: "{app}\ParaphraseTool.exe"; Description: "Launch Paraphrase Tool"; Flags: nowait postinstall skipifsilent
