#include <QtGui>
#include "WarpWindow.h"

int main(int argc, char **argv)
{
	QApplication app(argc, argv);

	WarpWindow w;
	w.show();
	w.move(1300-640,0);
	
	return app.exec();
}