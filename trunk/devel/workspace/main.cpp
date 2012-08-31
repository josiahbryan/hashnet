#include "WorkspaceWindow.h"

int main(int argc, char **argv)
{
	QApplication app(argc, argv);
	
	WorkspaceWindow w;
	//w.show();
	w.showMaximized();
	
	return app.exec();
}
