#ifndef WarpWindow_H
#define WarpWindow_H

#include <QtGui>

class PolyPointInfo
{
public:
	PolyPointInfo(QPolygonF *p, int x)
		: poly(p)
		, point(x)
		{}
		
	QPolygonF *poly;
	int point;
};

class ImagePoly
{
public:
	ImagePoly(QRect r,QPolygonF p)
		: rect(r)
		, poly(p)
		{}

	QRect rect;
	QPolygonF poly;
};

class WarpWindow : public QWidget
{
	Q_OBJECT
public:
	WarpWindow();
	QSize sizeHint() { return QSize(320,240); }

protected:
	void mousePressEvent(QMouseEvent *);
	void mouseMoveEvent(QMouseEvent *);
	void mouseReleaseEvent(QMouseEvent *);
	void paintEvent(QPaintEvent *);
	
protected slots:
	void render();

private:
	QImage m_image;
	QImage m_rendered;

	//QList<QPolygonF> m_polys;
	QList<ImagePoly*> m_polys;
	QHash<ImagePoly*, QPolygonF> m_origPolys;
	QList<PolyPointInfo> m_selectedPoints;
	bool m_mouseDown;

	//QPointF m_boundsTopLeft;
	QPointF m_dragStartPoint;
	QRectF m_bounds;
	QPointF m_startMousePoint;
	QPointF m_startBoundsTL;
	QPointF m_gridPoint;

	QTimer m_renderTimer;

	bool m_subdivClick;
};

#endif