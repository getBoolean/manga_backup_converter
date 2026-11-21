; BundleDir is the package written by scripts/package_cli.dart (bin, lib,
; runtime, licenses). The layout is kept: the executable finds its native code
; assets in ..\lib and its bundled runtime (JRE, Tachi worker, WebView helper)
; in ..\runtime.
#ifndef BundleDir
  #define BundleDir "..\..\..\build\package\windows-x64"
#endif
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
AppName=MangaBackupConverter CLI
AppVersion={#AppVersion}
AppPublisher=manga_backup_converter
DefaultDirName={autopf}\MangaBackupConverterCLI
DefaultGroupName=MangaBackupConverter CLI
OutputBaseFilename=mangabackupconverter-cli-windows-setup
Compression=lzma2
SolidCompression=yes
PrivilegesRequired=lowest
ChangesEnvironment=yes
UninstallDisplayIcon={app}\bin\mangabackupconverter_cli.exe

[InstallDelete]
; A previous version's runtime (an older JRE) must not survive an upgrade.
Type: filesandordirs; Name: "{app}\runtime"
; Earlier versions installed the executable in {app} itself; remove it so an
; upgraded machine cannot keep running the old CLI. (The old {app} PATH entry
; is left: it no longer holds an executable, and removing it by substring would
; also cut the new {app}\bin entry.)
Type: files; Name: "{app}\mangabackupconverter_cli.exe"

[Files]
Source: "{#BundleDir}\bin\*"; DestDir: "{app}\bin"; Flags: ignoreversion recursesubdirs
Source: "{#BundleDir}\lib\*"; DestDir: "{app}\lib"; Flags: ignoreversion recursesubdirs
Source: "{#BundleDir}\runtime\*"; DestDir: "{app}\runtime"; Flags: ignoreversion recursesubdirs
Source: "{#BundleDir}\licenses\*"; DestDir: "{app}\licenses"; Flags: ignoreversion recursesubdirs

[Icons]
Name: "{group}\Uninstall MangaBackupConverter CLI"; Filename: "{uninstallexe}"

[Code]
procedure AddToPath(Dir: String);
var
  CurrentPath: String;
begin
  if not RegQueryStringValue(HKCU, 'Environment', 'Path', CurrentPath) then
    CurrentPath := '';
  if Pos(Uppercase(Dir), Uppercase(CurrentPath)) = 0 then
  begin
    if CurrentPath <> '' then
      CurrentPath := CurrentPath + ';';
    CurrentPath := CurrentPath + Dir;
    RegWriteStringValue(HKCU, 'Environment', 'Path', CurrentPath);
  end;
end;

procedure RemoveFromPath(Dir: String);
var
  CurrentPath, UpperDir, UpperPath: String;
  P: Integer;
begin
  if not RegQueryStringValue(HKCU, 'Environment', 'Path', CurrentPath) then
    Exit;
  UpperDir := Uppercase(Dir);
  UpperPath := Uppercase(CurrentPath);
  P := Pos(UpperDir, UpperPath);
  if P > 0 then
  begin
    { Remove the directory and any trailing or leading semicolon }
    Delete(CurrentPath, P, Length(Dir));
    if (P <= Length(CurrentPath)) and (CurrentPath[P] = ';') then
      Delete(CurrentPath, P, 1)
    else if (P > 1) and (CurrentPath[P - 1] = ';') then
      Delete(CurrentPath, P - 1, 1);
    RegWriteStringValue(HKCU, 'Environment', 'Path', CurrentPath);
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    AddToPath(ExpandConstant('{app}\bin'));
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
    RemoveFromPath(ExpandConstant('{app}\bin'));
end;
