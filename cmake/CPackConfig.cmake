# CPack configuration for waywallen.
#
# Produces DEB / RPM / TGZ packages via `cpack -G <gen>` after a normal
# install. Components map to the installer chunks defined here:
#   * Daemon  — Rust daemon binary
#   * UI      — Qt/QML executable + .desktop / icons / metainfo
#   * Plugins — image + mpv renderer subprocesses and their manifests
#   * Bridge  — C ABI headers + import lib (devel; opt-in)

include_guard(GLOBAL)

set(CPACK_PACKAGE_NAME            "waywallen")
set(CPACK_PACKAGE_VENDOR          "waywallen")
set(CPACK_PACKAGE_CONTACT         "hypengn@gmail.com")
set(CPACK_PACKAGE_DESCRIPTION_SUMMARY
    "Wallpaper daemon with Qt UI and renderer plugins for Wayland")
set(CPACK_PACKAGE_HOMEPAGE_URL    "https://github.com/waywallen/waywallen")
set(CPACK_RESOURCE_FILE_LICENSE   "${CMAKE_CURRENT_SOURCE_DIR}/LICENSE")

set(CPACK_PACKAGE_VERSION_MAJOR   "${PROJECT_VERSION_MAJOR}")
set(CPACK_PACKAGE_VERSION_MINOR   "${PROJECT_VERSION_MINOR}")
set(CPACK_PACKAGE_VERSION_PATCH   "${PROJECT_VERSION_PATCH}")

# Stage into /usr regardless of the dev-time CMAKE_INSTALL_PREFIX.
set(CPACK_PACKAGING_INSTALL_PREFIX "/usr")

set(CPACK_GENERATOR "TGZ")
set(CPACK_SOURCE_GENERATOR "TGZ")
set(CPACK_SOURCE_IGNORE_FILES
    "/build/" "/build-.*/" "/target/" "/install/" "/\\\\.git/" "/\\\\.cache/"
    "/\\\\.vscode/" "\\\\.swp$")

# Strip release binaries to keep package size sane.
set(CPACK_STRIP_FILES TRUE)

# --- Components -------------------------------------------------------------
set(CPACK_COMPONENTS_ALL Daemon UI Plugins)
set(CPACK_COMPONENT_DAEMON_DISPLAY_NAME  "Daemon")
set(CPACK_COMPONENT_UI_DISPLAY_NAME      "Qt UI")
set(CPACK_COMPONENT_PLUGINS_DISPLAY_NAME "Renderer plugins")
set(CPACK_COMPONENT_BRIDGE_DISPLAY_NAME  "Plugin SDK (devel)")

set(CPACK_COMPONENT_UI_DEPENDS      Daemon)
set(CPACK_COMPONENT_PLUGINS_DEPENDS Daemon)

# Default: ship Daemon + UI + Plugins as one bundle. Bridge stays opt-in.
set(CPACK_DEB_COMPONENT_INSTALL OFF)
set(CPACK_RPM_COMPONENT_INSTALL OFF)
set(CPACK_ARCHIVE_COMPONENT_INSTALL OFF)

# --- Debian -----------------------------------------------------------------
set(CPACK_DEBIAN_PACKAGE_MAINTAINER       "${CPACK_PACKAGE_CONTACT}")
set(CPACK_DEBIAN_PACKAGE_SECTION          "x11")
set(CPACK_DEBIAN_PACKAGE_PRIORITY         "optional")
set(CPACK_DEBIAN_PACKAGE_HOMEPAGE         "${CPACK_PACKAGE_HOMEPAGE_URL}")
set(CPACK_DEBIAN_PACKAGE_SHLIBDEPS        ON)
set(CPACK_DEBIAN_FILE_NAME                DEB-DEFAULT)

# --- RPM --------------------------------------------------------------------
set(CPACK_RPM_PACKAGE_LICENSE             "GPL-3.0-or-later")
set(CPACK_RPM_PACKAGE_GROUP               "Applications/System")
set(CPACK_RPM_PACKAGE_URL                 "${CPACK_PACKAGE_HOMEPAGE_URL}")
set(CPACK_RPM_PACKAGE_AUTOREQ             ON)
# QML effect modules are loaded dynamically, so RPM's ELF dependency scanner
# cannot discover them from the executable. QtQuick.Effects is provided by
# qt6-declarative-imports; the old Qt5Compat effects module is no longer used.
set(CPACK_RPM_PACKAGE_REQUIRES            "qt6-declarative-imports")
set(CPACK_RPM_FILE_NAME                   RPM-DEFAULT)
# Keep the systemd user-unit lifecycle aligned with the distribution helpers:
# a newly installed package follows the preset, while a user's later disable
# choice is retained across upgrades.
set(CPACK_RPM_PRE_INSTALL_SCRIPT_FILE
    "${CMAKE_CURRENT_SOURCE_DIR}/packaging/rpm/waywallen.preinstall.sh")
set(CPACK_RPM_POST_INSTALL_SCRIPT_FILE
    "${CMAKE_CURRENT_SOURCE_DIR}/packaging/rpm/waywallen.postinstall.sh")
set(CPACK_RPM_PRE_UNINSTALL_SCRIPT_FILE
    "${CMAKE_CURRENT_SOURCE_DIR}/packaging/rpm/waywallen.preuninstall.sh")
set(CPACK_RPM_POST_UNINSTALL_SCRIPT_FILE
    "${CMAKE_CURRENT_SOURCE_DIR}/packaging/rpm/waywallen.postuninstall.sh")
# Don't claim ownership of standard system dirs.
set(CPACK_RPM_EXCLUDE_FROM_AUTO_FILELIST_ADDITION
    "/usr/lib/systemd"
    "/usr/lib/systemd/user"
    "/usr/lib/systemd/user-preset"
    "/usr/share/applications"
    "/usr/share/metainfo"
    "/usr/share/icons"
    "/usr/share/icons/hicolor"
    "/usr/share/icons/hicolor/scalable"
    "/usr/share/icons/hicolor/scalable/apps")

include(CPack)
