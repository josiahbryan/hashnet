#ifndef WorkspaceGraphicsView_H
#define WorkspaceGraphicsView_H

#include <QtGui>

//class MapGraphicsScene;
class WorkspaceGraphicsView : public QGraphicsView
{
	Q_OBJECT
public:
	WorkspaceGraphicsView();
	void scaleView(qreal scaleFactor);

	double scaleFactor() { return m_scaleFactor; }

	void reset();
	
	//void setMapScene(MapGraphicsScene *);

public slots:
	void zoomIn();
	void zoomOut();

	void setStatusMessage(QString);
	
protected slots:
	void updateViewportLayout();

protected:

	void keyPressEvent(QKeyEvent *event);
	void mouseMoveEvent(QMouseEvent * mouseEvent);
	void wheelEvent(QWheelEvent *event);
	void showEvent(QShowEvent *);
	//void drawBackground(QPainter *painter, const QRectF &rect);
	
	double m_scaleFactor;
	
	QLayout *m_viewportLayout;
	
	//MapGraphicsScene *m_gs;
	QLabel *m_hudLabel;

	QLabel *m_statusLabel;
};

#endif
