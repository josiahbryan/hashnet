#include "WorkspaceWindow.h"
#include "WorkspaceGraphicsView.h"
#include "WorkspaceScene.h"
#include "MjpegThread.h"

#define SETTINGS_FILE "workspace.ini"

WorkspaceWindow::WorkspaceWindow()
	: QMainWindow()
{
 	createActions();
// 	createToolBox();
// 	createMenus();
	createToolbars();

	m_scene = new WorkspaceScene();
	m_scene->setSceneRect(QRectF(0, 0, 5000, 5000));
// 	connect(scene, SIGNAL(itemInserted(DiagramItem*)),
// 		this, SLOT(itemInserted(DiagramItem*)));
// 	connect(scene, SIGNAL(textInserted(QGraphicsTextItem*)),
// 		this, SLOT(textInserted(QGraphicsTextItem*)));
// 	connect(scene, SIGNAL(itemSelected(QGraphicsItem*)),
// 		this, SLOT(itemSelected(QGraphicsItem*)));

	connect(m_scene, SIGNAL(selectionChanged()), this, SLOT(selectionChanged()));
	
	QHBoxLayout *layout = new QHBoxLayout;
	layout->setContentsMargins(0,0,0,0);
// 	layout->addWidget(toolBox);
	//m_view = new QGraphicsView(m_scene);
	m_view = new WorkspaceGraphicsView();
	m_view->setScene(m_scene);
	layout->addWidget(m_view);
	
	QWidget *widget = new QWidget;
	widget->setLayout(layout);
	
	setCentralWidget(widget);
	setWindowTitle(tr("Information Awareness Workspace"));
	setUnifiedTitleAndToolBarOnMac(true);
	
	
	// Add some test images
	MjpegThread *feed = new MjpegThread();
	feed->connectTo("bryanhq.homelinux.com", 80, "/mux");

	int camIdx = 1;
	int imgWidth = 320, imgHeight = 240;
	for(int row=0; row<2; row++)
	{
		for(int col=0; col<3; col++)
		{
			WorkspaceCameraFeedItem *cam = new WorkspaceCameraFeedItem();
			cam->setVideoSource(feed);
			
			cam->setPos(col * imgWidth, row * imgHeight);
			cam->setSubrect(QRect(col * imgWidth, row * imgHeight, imgWidth, imgHeight));
			cam->setItemId(camIdx ++); // arbitrary item id for coorleation of settings across loads

			m_scene->addItem(cam);
			m_items << cam;
		}
	}
	
	loadSettings();

// 	WorkspaceCameraFeedItem *cam = new WorkspaceCameraFeedItem();
// 	//cam->setVideoSource(feed);
// 
// 	cam->setPos(320, 240);
// 	cam->setSubrect(QRect(100,100,320,240));
// 	cam->setItemId(1); // arbitrary item id for coorleation of settings across loads

// 	m_scene->addItem(cam);
// 	m_items << cam;

	m_view->centerOn(m_items.first());
}

void WorkspaceWindow::loadSettings()
{
	QSettings settings(SETTINGS_FILE, QSettings::IniFormat);

	// TODO create m_items list on the fly from the loaded data
	
	foreach(WorkspaceItem *item, m_items)
	{
		QVariantMap map = settings.value(tr("items/%1").arg(item->itemId())).toMap();
		//qDebug() << "WorkspaceWindow::loadSettings(): item:"<<(QObject*)item<<", map:"<<map;
		item->loadSettings(map);
	}
}

void WorkspaceWindow::saveSettings()
{
	QSettings settings(SETTINGS_FILE, QSettings::IniFormat);

	// TODO save class names so we can create m_items when we load 
	
	foreach(WorkspaceItem *item, m_items)
	{
		QVariant map = item->saveSettings();
		//qDebug() << "WorkspaceWindow::saveSettings(): item:"<<(QObject*)item<<", map:"<<map;
		settings.setValue(tr("items/%1").arg(item->itemId()), map);
	}
}

void WorkspaceWindow::closeEvent(QCloseEvent *)
{
	//qDebug() << "WorkspaceWindow::closeEvent()";

	// Just disabled while debugging
	saveSettings();
}

void WorkspaceWindow::selectionChanged()
{
	QList<QGraphicsItem *> items = m_scene->selectedItems();

	double rotation = 0.0;
	double opacity = 1.0;
	
	m_selectedItems.clear();
	foreach(QGraphicsItem *item, items)
	{
		WorkspaceItem *w = dynamic_cast<WorkspaceItem *>(item);
		if(w)
			m_selectedItems << w;

		rotation = item->rotation();
		opacity = item->opacity();
	}

	m_rotationBox->setValue(rotation);
	m_rotationToolbar->setEnabled(!m_selectedItems.isEmpty());

	m_opacityBox->setValue(opacity);
	m_opacityToolbar->setEnabled(!m_selectedItems.isEmpty());
}

void WorkspaceWindow::rotationValueChanged(double r)
{
	foreach(WorkspaceItem *w, m_selectedItems)
		w->setRotation(r);
}

void WorkspaceWindow::opacityValuechanged(double o)
{
	foreach(WorkspaceItem *w, m_selectedItems)
		w->setOpacity(o);
}

void WorkspaceWindow::createActions()
{
	m_toFrontAction = new QAction(QIcon("images/bringtofront.png"), tr("Bring to &Front"), this);
	m_toFrontAction->setShortcut(tr("Ctrl+F"));
	m_toFrontAction->setStatusTip(tr("Bring item to front"));
	connect(m_toFrontAction, SIGNAL(triggered()), this, SLOT(bringToFront()));

	m_sendBackAction = new QAction(QIcon("images/sendtoback.png"), tr("Send to &Back"), this);
	m_sendBackAction->setShortcut(tr("Ctrl+B"));
	m_sendBackAction->setStatusTip(tr("Send item to back"));
	connect(m_sendBackAction, SIGNAL(triggered()), this, SLOT(sendToBack()));

// 	m_deleteAction = new QAction(QIcon("images/delete.png"), tr("&Delete"), this);
// 	m_deleteAction->setShortcut(tr("Delete"));
// 	m_deleteAction->setStatusTip(tr("Delete item"));
// 	connect(m_deleteAction, SIGNAL(triggered()), this, SLOT(deleteItem()));

	m_exitAction = new QAction(tr("E&xit"), this);
	m_exitAction->setShortcuts(QKeySequence::Quit);
	m_exitAction->setStatusTip(tr("Quit"));
	connect(m_exitAction, SIGNAL(triggered()), this, SLOT(close()));

	m_rotateLeftAction = new QAction(QIcon("images/object-rotate-left.png"), tr("Rotate &Left"), this);
	m_rotateLeftAction->setShortcut(tr("Rotate Left"));
	m_rotateLeftAction->setStatusTip(tr("Rotate Left"));
	connect(m_rotateLeftAction, SIGNAL(triggered()), this, SLOT(rotateLeft()));

	m_rotateRightAction = new QAction(QIcon("images/object-rotate-right.png"), tr("Rotate &Right"), this);
	m_rotateRightAction->setShortcut(tr("Rotate Right"));
	m_rotateRightAction->setStatusTip(tr("Rotate Right"));
	connect(m_rotateRightAction, SIGNAL(triggered()), this, SLOT(rotateRight()));

}

void WorkspaceWindow::createToolbars()
{
	QToolBar *toolbar = addToolBar(tr("Edit"));
	toolbar->addAction(m_toFrontAction);
	toolbar->addAction(m_sendBackAction);
	
	m_rotationToolbar = addToolBar(tr("Rotation"));

//	QToolButton *tb;

// 	tb = new QToolButton();
// 	tb->setIcon(QPixmap("images/object-rotate-left.png"));
// 	connect(tb, SIGNAL(clicked()), this, SLOT(rotateLeft()));
// 	m_rotationToolbar->addWidget(tb);
	m_rotationToolbar->addAction(m_rotateLeftAction);

	m_rotationBox = new QDoubleSpinBox();
	m_rotationBox->setMinimum(-360);
	m_rotationBox->setMaximum(360);
	m_rotationBox->setValue(0);
	connect(m_rotationBox, SIGNAL(valueChanged(double)), this, SLOT(rotationValueChanged(double)));

	m_rotationToolbar->addWidget(m_rotationBox);
	
// 	tb = new QToolButton();
// 	tb->setIcon(QPixmap("images/object-rotate-right.png"));
// 	connect(tb, SIGNAL(clicked()), this, SLOT(rotateRight()));
// 	m_rotationToolbar->addWidget(tb);
	m_rotationToolbar->addAction(m_rotateRightAction);

	m_rotationToolbar->setEnabled(false);

	m_opacityToolbar = addToolBar(tr("Opacity"));
	
	m_opacityBox = new QDoubleSpinBox();
	m_opacityBox->setMinimum(0);
	m_opacityBox->setMaximum(1);
	m_opacityBox->setValue(0);
	m_opacityBox->setSingleStep(0.1);
	connect(m_opacityBox, SIGNAL(valueChanged(double)), this, SLOT(opacityValuechanged(double)));

	m_opacityToolbar->addWidget(new QLabel("Opacity:"));
	m_opacityToolbar->addWidget(m_opacityBox);
	
	/// TODO: Add a 'zoom' toolbar based on the following from diagramscene/mainwindow.cpp:
// 	void MainWindow::sceneScaleChanged(const QString &scale)
// 	{
// 	double newScale = scale.left(scale.indexOf(tr("%"))).toDouble() / 100.0;
// 	QMatrix oldMatrix = view->matrix();
// 	view->resetMatrix();
// 	view->translate(oldMatrix.dx(), oldMatrix.dy());
// 	view->scale(newScale, newScale);
// 	}

}

void WorkspaceWindow::rotateLeft()
{
	m_rotationBox->setValue(m_rotationBox->value() - 1);
}

void WorkspaceWindow::rotateRight()
{
	m_rotationBox->setValue(m_rotationBox->value() + 1);
}

void WorkspaceWindow::bringToFront()
{
	if (m_scene->selectedItems().isEmpty())
		return;

	QGraphicsItem *selectedItem = m_scene->selectedItems().first();
	QList<QGraphicsItem *> overlapItems = selectedItem->collidingItems();

	qreal zValue = 0;
	foreach (QGraphicsItem *item, overlapItems)
	{
		if (item->zValue() >= zValue)
			zValue = item->zValue() + 0.1;
	}
	selectedItem->setZValue(zValue);
}

void WorkspaceWindow::sendToBack()
{
	if (m_scene->selectedItems().isEmpty())
		return;

	QGraphicsItem *selectedItem = m_scene->selectedItems().first();
	QList<QGraphicsItem *> overlapItems = selectedItem->collidingItems();

	qreal zValue = 0;
	foreach (QGraphicsItem *item, overlapItems)
	{
		if (item->zValue() <= zValue)
			zValue = item->zValue() - 0.1;
	}
	selectedItem->setZValue(zValue);
}
