TEMPLATE = app
TARGET = 
DEPENDPATH += .
INCLUDEPATH += .

QT += network multimedia opengl

DEFINES += OPENCV_ENABLED
LIBS += -L/usr/local/lib -lcv -lcxcore -L/opt/OpenCV-2.1.0/lib
INCLUDEPATH += /opt/OpenCV-2.1.0/include

# Input
HEADERS += \
	WorkspaceScene.h \
	WorkspaceWindow.h \
	WorkspaceGraphicsView.h
	
SOURCES += \
	main.cpp \
	WorkspaceScene.cpp \
	WorkspaceWindow.cpp \
	WorkspaceGraphicsView.cpp

RESOURCES += resources.qrc

# Build tmp file location
MOC_DIR = .build
OBJECTS_DIR = .build
RCC_DIR = .build
UI_DIR = .build

# Include from livepro
VPATH += /opt/livepro/gfxengine
DEPENDPATH += /opt/livepro/gfxengine
INCLUDEPATH += /opt/livepro/gfxengine

# Input
HEADERS += \
	VideoWidget.h \
	VideoReceiver.h \
	VideoFrame.h \
	VideoSource.h \
	VideoConsumer.h \
	MjpegThread.h
	
SOURCES += \
	VideoWidget.cpp \
	VideoReceiver.cpp \
	VideoFrame.cpp \
	VideoSource.cpp \
	VideoConsumer.cpp \
	MjpegThread.cpp 

