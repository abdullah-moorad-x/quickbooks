; Inno Setup script for QuickBill By Abdullah
; Build the Flutter Windows release first:
;   flutter build windows --release --tree-shake-icons

; Metadata macros
; --------------------------------------------------
; Adjust version if you bump pubspec version
; (build metadata "+1" is not used here)
; --------------------------------------------------
#define MyAppName "QuickBill By Abdullah"
#define MyAppVersion "1.0.3"
#define MyAppPublisher "Abdullah"
#define MyAppExeName "QuickBill_By_Abdullah.exe"
; AppId GUID (keep stable across versions). Use doubled braces per Inno docs.
; Example: AppId={{GUID}}
; Do not wrap in a macro to avoid preprocessor brace handling.

[Setup]
AppId={{E5E1C6C3-2E8F-47B4-9C35-4D7BAE41D4C2}}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
OutputDir=dist
OutputBaseFilename=QuickBill_By_Abdullah_Installer
SetupIconFile=windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2
SolidCompression=yes
DisableDirPage=no
DisableProgramGroupPage=no
UsePreviousAppDir=yes
WizardStyle=classic
; Brief note on finish page: first run will re-export reports automatically
InfoAfterFile=installer_note.txt

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional icons:"; Flags: unchecked

[Files]
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{commondesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent

