cmake_minimum_required(VERSION 3.21)
project(ipvexa VERSION 0.4.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 6.5 REQUIRED COMPONENTS Core Gui Quick QuickControls2 Multimedia Network)
find_package(PkgConfig REQUIRED)
pkg_check_modules(FFMPEG REQUIRED IMPORTED_TARGET libavformat libavcodec libavutil libswscale)

qt_standard_project_setup(REQUIRES 6.5)

qt_add_executable(ipvexa
    src/main.cpp
    src/ApiClient.h src/ApiClient.cpp
    src/PlaybackClock.h src/PlaybackClock.cpp
    src/VideoPlayer.h src/VideoPlayer.cpp src/LivePacer.h
)

target_include_directories(ipvexa PRIVATE src)

set_source_files_properties(qml/Theme.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)

qt_add_qml_module(ipvexa
    URI Ipvexa
    VERSION 1.0
    # The import scan links QML plugins into static Qt builds. Distribution Qt is
    # shared and loads them at run time; skipping it also avoids a warning per plugin.
    NO_IMPORT_SCAN
    QML_FILES
        qml/Main.qml
        qml/Theme.qml
        qml/LoginView.qml
        qml/MainView.qml
        qml/ResourceTree.qml
        qml/SceneView.qml
        qml/CameraTile.qml
        qml/Timeline.qml
        qml/CameraDialog.qml
        qml/IconButton.qml
        qml/ToolText.qml
        qml/PtzControls.qml
        qml/AppDialog.qml
        qml/TileIcon.qml
        qml/TileButton.qml
        qml/RightPanel.qml
        qml/AppButton.qml
        qml/Segmented.qml
        qml/GridGlyph.qml
        qml/ConfirmDialog.qml
        qml/FieldLabel.qml
        qml/PasswordDialog.qml
        qml/UsersDialog.qml
        qml/TabStrip.qml
        qml/Logo.qml
        qml/ToolSep.qml
        qml/Stepper.qml
        qml/CalendarPopup.qml
        qml/BookmarkDialog.qml
        qml/ExportDialog.qml
        qml/MotionZoneEditor.qml
        qml/NotificationsDialog.qml
        qml/AuditDialog.qml
        qml/VideoWall.qml
        qml/ServerSettingsDialog.qml
        qml/Cells.js
        qml/LayoutEngine.js
)

target_link_libraries(ipvexa PRIVATE
    Qt6::Core Qt6::Gui Qt6::Quick Qt6::QuickControls2 Qt6::Multimedia Qt6::Network
    PkgConfig::FFMPEG
)

install(TARGETS ipvexa RUNTIME DESTINATION bin)

# Unit tests for the layout engine: cmake --build build --target layout_tests && build/layout_tests
find_package(Qt6 REQUIRED COMPONENTS Qml)
add_executable(layout_tests EXCLUDE_FROM_ALL tests/layout_tests.cpp)
target_compile_definitions(layout_tests PRIVATE IPVEXA_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(layout_tests PRIVATE Qt6::Core Qt6::Qml)

# Simulation of live pacing (catching up after pauses, drifting camera clocks):
# cmake --build build --target pacer_tests && build/pacer_tests
add_executable(pacer_tests EXCLUDE_FROM_ALL tests/pacer_tests.cpp)
