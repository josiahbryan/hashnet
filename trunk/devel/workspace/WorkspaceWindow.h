#ifndef WorkspaceWindow_H
#define WorkspaceWindow_H

#include <QtGui>

class WorkspaceGraphicsView;
class WorkspaceScene;
class WorkspaceItem;
class WorkspaceWindow : public QMainWindow
{
	Q_OBJECT

public:
	WorkspaceWindow();

protected slots:
	void rotateLeft();
	void rotateRight();
	void rotationValueChanged(double);
	void opacityValuechanged(double);
	void selectionChanged();
	void bringToFront();
	void sendToBack();
	
protected:
	void createToolbars();
	void createActions();
	
	void closeEvent(QCloseEvent *);

	void saveSettings();
	void loadSettings();

protected:
	QAction *m_exitAction;
// 	QAction *m_addAction;
// 	QAction *m_deleteAction;

	QAction *m_toFrontAction;
	QAction *m_sendBackAction;
// 	QAction *m_aboutAction;

	QAction *m_rotateLeftAction;
	QAction *m_rotateRightAction;
	
	WorkspaceScene *m_scene;
	//QGraphicsView *m_view;
	WorkspaceGraphicsView *m_view;

	QList<WorkspaceItem *> m_items;
	QList<WorkspaceItem *> m_selectedItems;

	QToolBar *m_rotationToolbar;
	QDoubleSpinBox *m_rotationBox;

	QToolBar *m_opacityToolbar;
	QDoubleSpinBox *m_opacityBox;
};

#endif
//WorkspaceWindow_H
