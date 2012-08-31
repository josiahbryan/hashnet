#ifndef WorkspaceScene_H
#define WorkspaceScene_H

#include <QtGui>


#include "VideoSource.h"
#include "VideoConsumer.h"

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

class WorkspaceItem : public QObject,
		      public QGraphicsItem
{
	Q_OBJECT
public:
	WorkspaceItem();

	virtual bool setSize(QSizeF size);
	QSizeF size() { return m_size; }
	
	virtual void setSize(double x, double y) { setSize(QSizeF(x, y)); }

	virtual void setItemId(int id) { m_id = id; }
	virtual int itemId() { return m_id; }

	virtual void loadSettings(QVariantMap&);
	virtual QVariantMap saveSettings();

	// QGraphicsItem::
	QRectF boundingRect() const;
	
protected:
	int m_id;
	QSizeF m_size;
	QRectF m_boundingRect;
};

class WorkspaceCameraFeedItem : public WorkspaceItem,
				public VideoConsumer
{
	Q_OBJECT
public:
	WorkspaceCameraFeedItem();
	~WorkspaceCameraFeedItem();
	
	void setSubrect(QRect);
	
	// QGraphicsItem::
	void paint(QPainter *painter, const QStyleOptionGraphicsItem *option, QWidget *widget);

	// WorkspaceItem::
	void loadSettings(QVariantMap&);
	QVariantMap saveSettings();
	
	bool setSize(QSizeF size);

public slots:
	void setVideoSource(VideoSource*);
	void disconnectVideoSource();

protected slots:
	void frameAvailable();
	void processFrame();

	void render();
	void hitRenderTimer();
	
protected:
	void mousePressEvent(QGraphicsSceneMouseEvent *);
	void mouseMoveEvent(QGraphicsSceneMouseEvent *);
	void mouseReleaseEvent(QGraphicsSceneMouseEvent *);
	
	VideoFramePtr m_frame;
	QImage m_image;
	VideoSource *m_source;
	QTimer m_processTimer;
	QRect m_subrect;
	
	QImage m_rendered;
	
	QList<ImagePoly*> m_polys;
	QHash<ImagePoly*, QPolygonF> m_origPolys;
	//QList<PolyPointInfo> m_selectedPoints;
	bool m_mouseDown;

	//QPointF m_boundsTopLeft;
	QPointF m_dragStartPoint;
	QRectF m_bounds;
	QPointF m_startMousePoint;
	QPointF m_startMouseOffset;
	QPointF m_startBoundsTL;
	QPointF m_gridPoint;

	QTimer m_renderTimer;

	bool m_subdivClick;
};


class WorkspaceScene : public QGraphicsScene
{
	Q_OBJECT
public:
	WorkspaceScene();

};


#endif
//WorkspaceScene_H

