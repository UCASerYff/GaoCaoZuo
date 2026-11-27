[Setup]
AppId=GaoSeries.GaoCaoZuo.Windows
AppName=搞操作
AppVersion={#AppVersion}
AppVerName=搞操作 V{#AppVersion}
AppPublisher=GaoSeries
VersionInfoVersion={#AppVersion}.{#BuildNumber}.0
VersionInfoProductVersion={#AppVersion}
DefaultDirName={localappdata}\Programs\GaoSeries\GaoCaoZuo
DefaultGroupName=搞操作
UninstallDisplayIcon={app}\GaoCaoZuo.exe
SetupIconFile=build\GaoCaoZuo.ico
PrivilegesRequired=lowest
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
MinVersion=10.0.17763
DisableProgramGroupPage=yes
ChangesAssociations=yes
Compression=lzma2/fast
SolidCompression=yes
WizardStyle=modern
Uninstallable=IsRegisteredInstall

[Files]
Source: "dist\GaoCaoZuo.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "dist\GaoCaoZuo-cli.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "build\notices\*"; DestDir: "{app}\Licenses"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{userprograms}\搞操作"; Filename: "{app}\GaoCaoZuo.exe"; Check: IsRegisteredInstall

[Registry]
Root: HKCU; Subkey: "Software\Classes\*\shell\GaoCaoZuo"; ValueType: string; ValueData: "用搞操作打开"; Flags: uninsdeletekey; Check: IsRegisteredInstall
Root: HKCU; Subkey: "Software\Classes\*\shell\GaoCaoZuo"; ValueType: string; ValueName: "MultiSelectModel"; ValueData: "Single"; Check: IsRegisteredInstall
Root: HKCU; Subkey: "Software\Classes\*\shell\GaoCaoZuo"; ValueType: string; ValueName: "Icon"; ValueData: "{app}\GaoCaoZuo.exe"; Check: IsRegisteredInstall
Root: HKCU; Subkey: "Software\Classes\*\shell\GaoCaoZuo\command"; ValueType: string; ValueData: """{app}\GaoCaoZuo.exe"" --paths ""%1"""; Check: IsRegisteredInstall
Root: HKCU; Subkey: "Software\Classes\Directory\shell\GaoCaoZuo"; ValueType: string; ValueData: "用搞操作打开"; Flags: uninsdeletekey; Check: IsRegisteredInstall
Root: HKCU; Subkey: "Software\Classes\Directory\shell\GaoCaoZuo"; ValueType: string; ValueName: "MultiSelectModel"; ValueData: "Single"; Check: IsRegisteredInstall
Root: HKCU; Subkey: "Software\Classes\Directory\shell\GaoCaoZuo"; ValueType: string; ValueName: "Icon"; ValueData: "{app}\GaoCaoZuo.exe"; Check: IsRegisteredInstall
Root: HKCU; Subkey: "Software\Classes\Directory\shell\GaoCaoZuo\command"; ValueType: string; ValueData: """{app}\GaoCaoZuo.exe"" --paths ""%1"""; Check: IsRegisteredInstall

[Code]
function IsRegisteredInstall: Boolean;
begin
  Result := ExpandConstant('{param:ISOLATEDSMOKE|0}') <> '1';
end;
