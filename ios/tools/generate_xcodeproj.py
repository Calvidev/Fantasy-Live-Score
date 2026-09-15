#!/usr/bin/env python3
"""Genera SleeperScore.xcodeproj/project.pbxproj.

Un `.pbxproj` es una lista de propiedades en formato OpenStep con identificadores
de 24 caracteres. Escribirlo a mano es pedir un error de sintaxis, así que se
genera desde esta descripción y se comprueba volviéndolo a leer
(`tools/check_pbxproj.py`).

Uso:  python3 tools/generate_xcodeproj.py
"""

from __future__ import annotations

import hashlib
import os
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROJECT_NAME = "SleeperScore"
APP_TARGET = "SleeperScore"
WIDGET_TARGET = "ScoreWidgetExtension"
BUNDLE_ID = "dev.calvi.sleeperscore"
DEPLOYMENT_TARGET = "17.0"
OBJECT_VERSION = 56  # Xcode 14 en adelante

SHARED_SOURCES = [
    "AppConfig.swift",
    "JSONSupport.swift",
    "JSONValue.swift",
    "SleeperModels.swift",
    "SleeperAPI.swift",
    "MatchupSnapshot.swift",
    "MatchupActivity.swift",
    "ScoringDetector.swift",
    "InjuryWatcher.swift",
    "MatchSimulator.swift",
    "SharedStore.swift",
    "KeychainStore.swift",
    "HostKind.swift",
    "Entitlements.swift",
    "AvatarLoader.swift",
    "HeadshotCache.swift",
    "PlayerCatalog.swift",
    "WeekStats.swift",
    "Projections.swift",
    "GameStatus.swift",
    "WinProbability.swift",
    "OptimalLineup.swift",
    "PlayerNews.swift",
    "SeasonHistory.swift",
    "FreeAgents.swift",
    "MatchupService.swift",
    "YahooSession.swift",
    "YahooHost.swift",
    "Theme.swift",
    "MatchupComponents.swift",
]
APP_SOURCES = [
    "SleeperScoreApp.swift",
    "ScoreboardModel.swift",
    "LiveActivityController.swift",
    "BackgroundRefresh.swift",
    "Notifier.swift",
    "RootView.swift",
    "ScoreboardView.swift",
    "AccountsView.swift",
    "PaywallView.swift",
    "Celebration.swift",
    "StandingsView.swift",
    "SeasonView.swift",
    "FreeAgentsView.swift",
    "PlayerDetailView.swift",
    "ShareCard.swift",
    "SleeperSettingsView.swift",
    "YahooAuth.swift",
    "YahooLeaguesView.swift",
]
WIDGET_SOURCES = [
    "ScoreWidgetBundle.swift",
    "ScoreProvider.swift",
    "LeagueIntent.swift",
    "ScoreWidgetViews.swift",
    "MatchupLiveActivity.swift",
]

FILE_TYPES = {
    ".swift": "sourcecode.swift",
    ".xcassets": "folder.assetcatalog",
    ".plist": "text.plist.xml",
    ".xcprivacy": "text.plist.xml",
    ".xcstrings": "text.json.xcstrings",
    ".wav": "audio.wav",
    ".entitlements": "text.plist.entitlements",
}


# --------------------------------------------------------------------------
# Serialización del formato OpenStep
# --------------------------------------------------------------------------

class Ref:
    """Referencia a otro objeto: se escribe `UUID /* comentario */`."""

    def __init__(self, uuid: str, comment: str | None = None):
        self.uuid = uuid
        self.comment = comment

    def render(self) -> str:
        return f"{self.uuid} /* {self.comment} */" if self.comment else self.uuid


BARE = re.compile(r"^[A-Za-z0-9_./]+$")


def quote(value: str) -> str:
    if value == "":
        return '""'
    if BARE.match(value):
        return value
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def render(value, indent: int) -> str:
    pad = "\t" * indent
    inner = "\t" * (indent + 1)
    if isinstance(value, Ref):
        return value.render()
    if isinstance(value, bool):
        raise TypeError("usa 0/1 o YES/NO, no booleanos de Python")
    if isinstance(value, int):
        return str(value)
    if isinstance(value, str):
        return quote(value)
    if isinstance(value, list):
        if not value:
            return "(\n" + pad + ")"
        items = "".join(f"{inner}{render(item, indent + 1)},\n" for item in value)
        return "(\n" + items + pad + ")"
    if isinstance(value, dict):
        keys = list(value.keys())
        # `isa` siempre primero, como hace Xcode; el resto en orden alfabético.
        keys.sort(key=lambda k: (k != "isa", k))
        items = ""
        for key in keys:
            items += f"{inner}{quote(key)} = {render(value[key], indent + 1)};\n"
        return "{\n" + items + pad + "}"
    raise TypeError(f"tipo no soportado: {type(value)}")


# --------------------------------------------------------------------------
# Identificadores estables
# --------------------------------------------------------------------------

_used: dict[str, str] = {}


def uid(name: str) -> str:
    digest = hashlib.md5(name.encode("utf-8")).hexdigest()[:24].upper()
    if digest in _used and _used[digest] != name:
        raise RuntimeError(f"colisión de identificadores: {name} y {_used[digest]}")
    _used[digest] = name
    return digest


def ref(name: str, comment: str | None = None) -> Ref:
    return Ref(uid(name), comment)


# --------------------------------------------------------------------------
# Construcción del proyecto
# --------------------------------------------------------------------------

objects: dict[str, dict] = {}


def add(name: str, body: dict) -> Ref:
    objects[uid(name)] = body
    return ref(name)


def file_type(filename: str) -> str:
    return FILE_TYPES.get(Path(filename).suffix, "text")


def file_ref(folder: str, filename: str) -> Ref:
    key = f"fileRef:{folder}/{filename}"
    add(key, {
        "isa": "PBXFileReference",
        "lastKnownFileType": file_type(filename),
        "path": filename,
        "sourceTree": "<group>",
    })
    return Ref(uid(key), filename)


def build_file(target: str, folder: str, filename: str, settings: dict | None = None) -> Ref:
    key = f"buildFile:{target}:{folder}/{filename}"
    body = {
        "isa": "PBXBuildFile",
        "fileRef": Ref(uid(f"fileRef:{folder}/{filename}"), filename),
    }
    if settings:
        body["settings"] = settings
    add(key, body)
    return Ref(uid(key), f"{filename} in {target}")


def group(key: str, children: list[Ref], *, path: str | None = None, name: str | None = None) -> Ref:
    body = {"isa": "PBXGroup", "children": children, "sourceTree": "<group>"}
    if path:
        body["path"] = path
    if name:
        body["name"] = name
    add(key, body)
    return Ref(uid(key), name or path or key)


def configuration_list(key: str, debug: Ref, release: Ref, comment: str) -> Ref:
    add(key, {
        "isa": "XCConfigurationList",
        "buildConfigurations": [debug, release],
        "defaultConfigurationIsVisible": 0,
        "defaultConfigurationName": "Release",
    })
    return Ref(uid(key), comment)


def build_configuration(key: str, name: str, settings: dict) -> Ref:
    add(key, {"isa": "XCBuildConfiguration", "buildSettings": settings, "name": name})
    return Ref(uid(key), name)


# -- ajustes de compilación --------------------------------------------------

COMMON = {
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "CLANG_ANALYZER_NONNULL": "YES",
    "CLANG_ENABLE_MODULES": "YES",
    "CLANG_ENABLE_OBJC_ARC": "YES",
    "COPY_PHASE_STRIP": "NO",
    "ENABLE_STRICT_OBJC_MSGSEND": "YES",
    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    "GCC_C_LANGUAGE_STANDARD": "gnu17",
    "GCC_NO_COMMON_BLOCKS": "YES",
    "IPHONEOS_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
    "MTL_FAST_MATH": "YES",
    "SDKROOT": "iphoneos",
    "SWIFT_VERSION": "5.0",
}

PROJECT_DEBUG = dict(COMMON, **{
    "DEBUG_INFORMATION_FORMAT": "dwarf",
    "ENABLE_TESTABILITY": "YES",
    "GCC_DYNAMIC_NO_PIC": "NO",
    "GCC_OPTIMIZATION_LEVEL": "0",
    "GCC_PREPROCESSOR_DEFINITIONS": ["DEBUG=1", "$(inherited)"],
    "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
    "ONLY_ACTIVE_ARCH": "YES",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)",
    "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
})

PROJECT_RELEASE = dict(COMMON, **{
    "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
    "ENABLE_NS_ASSERTIONS": "NO",
    "MTL_ENABLE_DEBUG_INFO": "NO",
    "SWIFT_COMPILATION_MODE": "wholemodule",
    "VALIDATE_PRODUCT": "YES",
})

APP_SETTINGS = {
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
    "CODE_SIGN_ENTITLEMENTS": "SleeperScore/SleeperScore.entitlements",
    "CODE_SIGN_STYLE": "Automatic",
    "CURRENT_PROJECT_VERSION": "1",
    "ENABLE_PREVIEWS": "YES",
    "GENERATE_INFOPLIST_FILE": "NO",
    "INFOPLIST_FILE": "SleeperScore/Info.plist",
    "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
    "MARKETING_VERSION": "1.0",
    "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
    "PRODUCT_NAME": "$(TARGET_NAME)",
    # NO a propósito: con YES, Xcode reescribe Localizable.xcstrings en cada
    # compilación para meterle las cadenas que encuentra, y entonces cada
    # `git pull` choca con el archivo. Las traducciones se mantienen en el
    # repositorio, no desde el editor de Xcode.
    "SWIFT_EMIT_LOC_STRINGS": "NO",
    "TARGETED_DEVICE_FAMILY": "1,2",
}

WIDGET_SETTINGS = {
    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
    "ASSETCATALOG_COMPILER_WIDGET_BACKGROUND_COLOR_NAME": "WidgetBackground",
    "CODE_SIGN_ENTITLEMENTS": "ScoreWidget/ScoreWidget.entitlements",
    "CODE_SIGN_STYLE": "Automatic",
    "CURRENT_PROJECT_VERSION": "1",
    "ENABLE_PREVIEWS": "YES",
    "GENERATE_INFOPLIST_FILE": "NO",
    "INFOPLIST_FILE": "ScoreWidget/Info.plist",
    "LD_RUNPATH_SEARCH_PATHS": [
        "$(inherited)",
        "@executable_path/Frameworks",
        "@executable_path/../../Frameworks",
    ],
    "MARKETING_VERSION": "1.0",
    "PRODUCT_BUNDLE_IDENTIFIER": f"{BUNDLE_ID}.widget",
    "PRODUCT_NAME": "$(TARGET_NAME)",
    "SKIP_INSTALL": "YES",
    "SWIFT_EMIT_LOC_STRINGS": "NO",
    "TARGETED_DEVICE_FAMILY": "1,2",
}


def equipo_de_firma_existente() -> str | None:
    """El DEVELOPMENT_TEAM que ya hubiera en el proyecto, si lo hay.

    Xcode lo escribe dentro del .pbxproj al elegir la cuenta. Regenerar sin
    conservarlo obligaría a volver a configurar la firma cada vez.
    """
    ruta = ROOT / f"{PROJECT_NAME}.xcodeproj" / "project.pbxproj"
    if not ruta.exists():
        return None
    encontrado = re.search(r"DEVELOPMENT_TEAM = ([A-Z0-9]+);", ruta.read_text(encoding="utf-8"))
    return encontrado.group(1) if encontrado else None


def build() -> str:
    equipo = equipo_de_firma_existente()
    if equipo:
        APP_SETTINGS["DEVELOPMENT_TEAM"] = equipo
        WIDGET_SETTINGS["DEVELOPMENT_TEAM"] = equipo

    # -- referencias a archivos ---------------------------------------------
    shared_refs = [file_ref("Shared", name) for name in SHARED_SOURCES]
    app_file_names = APP_SOURCES + [
        "Assets.xcassets", "Localizable.xcstrings", "InfoPlist.xcstrings",
        "anotacion.wav", "aviso.wav", "alerta.wav",
        "PrivacyInfo.xcprivacy", "Info.plist", "SleeperScore.entitlements"
    ]
    app_refs = [file_ref("SleeperScore", name) for name in app_file_names]
    widget_file_names = WIDGET_SOURCES + [
        "Assets.xcassets", "Localizable.xcstrings", "PrivacyInfo.xcprivacy",
        "Info.plist", "ScoreWidget.entitlements"
    ]
    widget_refs = [file_ref("ScoreWidget", name) for name in widget_file_names]

    app_product = add("product:app", {
        "isa": "PBXFileReference",
        "explicitFileType": "wrapper.application",
        "includeInIndex": 0,
        "path": f"{APP_TARGET}.app",
        "sourceTree": "BUILT_PRODUCTS_DIR",
    })
    app_product = Ref(app_product.uuid, f"{APP_TARGET}.app")

    widget_product = add("product:widget", {
        "isa": "PBXFileReference",
        "explicitFileType": "wrapper.app-extension",
        "includeInIndex": 0,
        "path": f"{WIDGET_TARGET}.appex",
        "sourceTree": "BUILT_PRODUCTS_DIR",
    })
    widget_product = Ref(widget_product.uuid, f"{WIDGET_TARGET}.appex")

    # -- grupos --------------------------------------------------------------
    shared_group = group("group:shared", shared_refs, path="Shared")
    app_group = group("group:app", app_refs, path="SleeperScore")
    widget_group = group("group:widget", widget_refs, path="ScoreWidget")
    products_group = group("group:products", [app_product, widget_product], name="Products")
    main_group = group(
        "group:main", [shared_group, app_group, widget_group, products_group]
    )

    # -- fases de compilación ------------------------------------------------
    app_sources = [build_file(APP_TARGET, "Shared", n) for n in SHARED_SOURCES]
    app_sources += [build_file(APP_TARGET, "SleeperScore", n) for n in APP_SOURCES]
    widget_sources = [build_file(WIDGET_TARGET, "Shared", n) for n in SHARED_SOURCES]
    widget_sources += [build_file(WIDGET_TARGET, "ScoreWidget", n) for n in WIDGET_SOURCES]

    app_resources = [
        build_file(APP_TARGET, "SleeperScore", "Assets.xcassets"),
        build_file(APP_TARGET, "SleeperScore", "PrivacyInfo.xcprivacy"),
        build_file(APP_TARGET, "SleeperScore", "Localizable.xcstrings"),
        build_file(APP_TARGET, "SleeperScore", "InfoPlist.xcstrings"),
        build_file(APP_TARGET, "SleeperScore", "anotacion.wav"),
        build_file(APP_TARGET, "SleeperScore", "aviso.wav"),
        build_file(APP_TARGET, "SleeperScore", "alerta.wav"),
    ]
    widget_resources = [
        build_file(WIDGET_TARGET, "ScoreWidget", "Assets.xcassets"),
        build_file(WIDGET_TARGET, "ScoreWidget", "PrivacyInfo.xcprivacy"),
        build_file(WIDGET_TARGET, "ScoreWidget", "Localizable.xcstrings"),
    ]

    app_sources_phase = add("phase:app:sources", {
        "isa": "PBXSourcesBuildPhase",
        "buildActionMask": 2147483647,
        "files": app_sources,
        "runOnlyForDeploymentPostprocessing": 0,
    })
    app_frameworks_phase = add("phase:app:frameworks", {
        "isa": "PBXFrameworksBuildPhase",
        "buildActionMask": 2147483647,
        "files": [],
        "runOnlyForDeploymentPostprocessing": 0,
    })
    app_resources_phase = add("phase:app:resources", {
        "isa": "PBXResourcesBuildPhase",
        "buildActionMask": 2147483647,
        "files": app_resources,
        "runOnlyForDeploymentPostprocessing": 0,
    })

    # El .appex del widget viaja dentro de la app, en PlugIns (spec 13).
    embed_build_file = add("buildFile:embed:widget", {
        "isa": "PBXBuildFile",
        "fileRef": widget_product,
        "settings": {"ATTRIBUTES": ["RemoveHeadersOnCopy"]},
    })
    embed_phase = add("phase:app:embed", {
        "isa": "PBXCopyFilesBuildPhase",
        "buildActionMask": 2147483647,
        "dstPath": "",
        "dstSubfolderSpec": 13,
        "files": [Ref(embed_build_file.uuid, f"{WIDGET_TARGET}.appex in Embed Foundation Extensions")],
        "name": "Embed Foundation Extensions",
        "runOnlyForDeploymentPostprocessing": 0,
    })

    widget_sources_phase = add("phase:widget:sources", {
        "isa": "PBXSourcesBuildPhase",
        "buildActionMask": 2147483647,
        "files": widget_sources,
        "runOnlyForDeploymentPostprocessing": 0,
    })
    widget_frameworks_phase = add("phase:widget:frameworks", {
        "isa": "PBXFrameworksBuildPhase",
        "buildActionMask": 2147483647,
        "files": [],
        "runOnlyForDeploymentPostprocessing": 0,
    })
    widget_resources_phase = add("phase:widget:resources", {
        "isa": "PBXResourcesBuildPhase",
        "buildActionMask": 2147483647,
        "files": widget_resources,
        "runOnlyForDeploymentPostprocessing": 0,
    })

    # -- configuraciones -----------------------------------------------------
    project_config_list = configuration_list(
        "configList:project",
        build_configuration("config:project:debug", "Debug", PROJECT_DEBUG),
        build_configuration("config:project:release", "Release", PROJECT_RELEASE),
        'Build configuration list for PBXProject "SleeperScore"',
    )
    app_config_list = configuration_list(
        "configList:app",
        build_configuration("config:app:debug", "Debug", APP_SETTINGS),
        build_configuration("config:app:release", "Release", APP_SETTINGS),
        f'Build configuration list for PBXNativeTarget "{APP_TARGET}"',
    )
    widget_config_list = configuration_list(
        "configList:widget",
        build_configuration("config:widget:debug", "Debug", WIDGET_SETTINGS),
        build_configuration("config:widget:release", "Release", WIDGET_SETTINGS),
        f'Build configuration list for PBXNativeTarget "{WIDGET_TARGET}"',
    )

    # -- objetivos -----------------------------------------------------------
    widget_target = add("target:widget", {
        "isa": "PBXNativeTarget",
        "buildConfigurationList": widget_config_list,
        "buildPhases": [widget_sources_phase, widget_frameworks_phase, widget_resources_phase],
        "buildRules": [],
        "dependencies": [],
        "name": WIDGET_TARGET,
        "productName": WIDGET_TARGET,
        "productReference": widget_product,
        "productType": "com.apple.product-type.app-extension",
    })
    widget_target = Ref(widget_target.uuid, WIDGET_TARGET)

    project_ref = ref("project", "Project object")

    container_proxy = add("proxy:widget", {
        "isa": "PBXContainerItemProxy",
        "containerPortal": project_ref,
        "proxyType": 1,
        "remoteGlobalIDString": widget_target.uuid,
        "remoteInfo": WIDGET_TARGET,
    })
    dependency = add("dependency:widget", {
        "isa": "PBXTargetDependency",
        "target": widget_target,
        "targetProxy": Ref(container_proxy.uuid, "PBXContainerItemProxy"),
    })

    app_target = add("target:app", {
        "isa": "PBXNativeTarget",
        "buildConfigurationList": app_config_list,
        "buildPhases": [
            app_sources_phase,
            app_frameworks_phase,
            app_resources_phase,
            embed_phase,
        ],
        "buildRules": [],
        "dependencies": [Ref(dependency.uuid, "PBXTargetDependency")],
        "name": APP_TARGET,
        "productName": APP_TARGET,
        "productReference": app_product,
        "productType": "com.apple.product-type.application",
    })
    app_target = Ref(app_target.uuid, APP_TARGET)

    objects[project_ref.uuid] = {
        "isa": "PBXProject",
        "attributes": {
            "BuildIndependentTargetsInParallel": 1,
            "LastSwiftUpdateCheck": 1600,
            "LastUpgradeCheck": 1600,
            "TargetAttributes": {
                app_target.uuid: {"CreatedOnToolsVersion": "16.0"},
                widget_target.uuid: {"CreatedOnToolsVersion": "16.0"},
            },
        },
        "buildConfigurationList": project_config_list,
        "compatibilityVersion": "Xcode 14.0",
        "developmentRegion": "es",
        "hasScannedForEncodings": 0,
        "knownRegions": ["en", "Base", "es"],
        "mainGroup": main_group,
        "productRefGroup": products_group,
        "projectDirPath": "",
        "projectRoot": "",
        "targets": [app_target, widget_target],
    }

    # -- documento -----------------------------------------------------------
    document = {
        "archiveVersion": 1,
        "classes": {},
        "objectVersion": OBJECT_VERSION,
        "objects": objects,
        "rootObject": project_ref,
    }
    header = "// !$*UTF8*$!\n"
    return header + render(document, 0) + "\n"


SCHEME = """<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1600"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{app_uuid}"
               BuildableName = "{app}.app"
               BlueprintName = "{app}"
               ReferencedContainer = "container:{project}.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{app_uuid}"
            BuildableName = "{app}.app"
            BlueprintName = "{app}"
            ReferencedContainer = "container:{project}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{app_uuid}"
            BuildableName = "{app}.app"
            BlueprintName = "{app}"
            ReferencedContainer = "container:{project}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""


def write_scheme(project_dir: Path) -> Path:
    """Esquema compartido: sin él, cada quien se genera el suyo al abrir."""
    schemes = project_dir / "xcshareddata" / "xcschemes"
    schemes.mkdir(parents=True, exist_ok=True)
    path = schemes / f"{APP_TARGET}.xcscheme"
    path.write_text(
        SCHEME.format(app_uuid=uid("target:app"), app=APP_TARGET, project=PROJECT_NAME),
        encoding="utf-8",
    )
    return path


def main() -> None:
    project_dir = ROOT / f"{PROJECT_NAME}.xcodeproj"
    os.makedirs(project_dir, exist_ok=True)
    target = project_dir / "project.pbxproj"
    target.write_text(build(), encoding="utf-8")
    print(f"escrito {target.relative_to(ROOT)} ({target.stat().st_size} bytes, "
          f"{len(objects)} objetos)")
    scheme = write_scheme(project_dir)
    print(f"escrito {scheme.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
