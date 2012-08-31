#include "WorkspaceGraphicsView.h"
//#include "3rdparty/flickcharm.h"
//#include "ImageUtils.h"

/// WorkspaceGraphicsView class implementation

	
WorkspaceGraphicsView::WorkspaceGraphicsView()
	: QGraphicsView()
{
#ifndef Q_OS_WIN
	srand ( time(NULL) );
#endif
	m_scaleFactor = 1.;

	#ifndef QT_NO_OPENGL
	//setViewport(new QGLWidget(QGLFormat(QGL::SampleBuffers)));
	#endif

	setCacheMode(CacheBackground);
	//setViewportUpdateMode(BoundingRectViewportUpdate);
	//setRenderHint(QPainter::Antialiasing);
	//setTransformationAnchor(AnchorUnderMouse);
#ifdef Q_OS_ANDROID
	setTransformationAnchor(QGraphicsView::AnchorViewCenter);
#endif
	setResizeAnchor(AnchorViewCenter);
	setDragMode(QGraphicsView::ScrollHandDrag);

	setRenderHints(QPainter::Antialiasing | QPainter::TextAntialiasing | QPainter::SmoothPixmapTransform );
	// if there are ever graphic glitches to be found, remove this again
	setOptimizationFlags(QGraphicsView::DontAdjustForAntialiasing | QGraphicsView::DontClipPainter | QGraphicsView::DontSavePainterState);

	//setCacheMode(QGraphicsView::CacheBackground);
	//setViewportUpdateMode(QGraphicsView::BoundingRectViewportUpdate);
	setViewportUpdateMode(QGraphicsView::SmartViewportUpdate);
	setOptimizationFlags(QGraphicsView::DontSavePainterState);

	setFrameStyle(QFrame::NoFrame);
	
	#ifdef Q_OS_ANDROID
	setVerticalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
	setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
	#endif
	
	
	QWidget *viewport = new QWidget();
	QVBoxLayout *vbox = new QVBoxLayout(viewport);
	QHBoxLayout *hbox;

// 	hbox = new QHBoxLayout();
// 	{
// 		hbox->setSpacing(0);
// 		hbox->addStretch(1);
// 
// 		m_hudLabel = new QLabel();
// 		hbox->addWidget(m_hudLabel);
// 
// 		vbox->addLayout(hbox);
// 	}

	vbox->addStretch(1);

	hbox = new QHBoxLayout();
	{
		hbox->setSpacing(0);
		hbox->addStretch(1);

		m_statusLabel = new QLabel();
		hbox->addWidget(m_statusLabel);

		m_statusLabel->hide();

		hbox->addStretch(1);
	}

	vbox->addLayout(hbox);
	
	hbox = new QHBoxLayout();
	{
		hbox->setSpacing(0);
		hbox->addStretch(1);
		
		QPushButton *btn;
		{
			btn = new QPushButton("-");
			btn->setStyleSheet("QPushButton {"
				#ifdef Q_OS_ANDROID
				"background: url(':/data/images/android-zoom-minus-button.png'); width: 117px; height: 47px; "
				#else
				"background: url(':/data/images/zoom-minus-button.png'); width: 58px; height: 24px; "
				#endif
				"padding:0; margin:0; border:none; color: transparent; outline: none; }");
			btn->setSizePolicy(QSizePolicy(QSizePolicy::Fixed, QSizePolicy::Fixed));
			btn->setAutoRepeat(true);
			btn->setMaximumSize(117,48);

			connect(btn, SIGNAL(clicked()), this, SLOT(zoomOut()));
			hbox->addWidget(btn);
		}
		
		{
			btn = new QPushButton("+");
			btn->setStyleSheet("QPushButton {"
				#ifdef Q_OS_ANDROID
				"background: url(':/data/images/android-zoom-plus-button.png'); width: 117px; height: 47px; "
				#else
				"background: url(':/data/images/zoom-plus-button.png'); width: 58px; height: 24px; "
				#endif
				"padding:0; margin:0; border:none; color: transparent; outline: none; }");
			btn->setSizePolicy(QSizePolicy(QSizePolicy::Fixed, QSizePolicy::Fixed));
			btn->setAttribute(Qt::WA_TranslucentBackground, true);
			btn->setAutoRepeat(true);
			btn->setMaximumSize(117,48);
			
			connect(btn, SIGNAL(clicked()), this, SLOT(zoomIn()));
			hbox->addWidget(btn);
		}
		
		hbox->addStretch(1);
	}
	
	vbox->addLayout(hbox);
	
	m_viewportLayout = vbox;
	setViewport(viewport);
	
	// Set a timer to update layout because it doesn't give buttons correct position right at the start
	QTimer::singleShot(500, this, SLOT(updateViewportLayout()));
	
	// Disable here because it interferes with the 'longpress' functionality in MapGraphicsScene
// 	FlickCharm *flickCharm = new FlickCharm(this);
// 	flickCharm->activateOn(this);
}

void WorkspaceGraphicsView::reset()
{
	resetTransform();
	m_scaleFactor = 1.;
}

void WorkspaceGraphicsView::zoomIn()
{
	scaleView(qreal(1.2));
}

void WorkspaceGraphicsView::zoomOut()
{
	scaleView(1 / qreal(1.2));
}

void WorkspaceGraphicsView::keyPressEvent(QKeyEvent *event)
{
	if(event->modifiers() & Qt::ControlModifier)
	{
		switch (event->key())
		{
			case Qt::Key_Plus:
				scaleView(qreal(1.2));
				break;
			case Qt::Key_Minus:
			case Qt::Key_Equal:
				scaleView(1 / qreal(1.2));
				break;
			default:
				QGraphicsView::keyPressEvent(event);
		}
	}
}


void WorkspaceGraphicsView::wheelEvent(QWheelEvent *event)
{
	scaleView(pow((double)2, event->delta() / 240.0));
}

void WorkspaceGraphicsView::scaleView(qreal scaleFactor)
{
	//qDebug() << "WorkspaceGraphicsView::scaleView: "<<scaleFactor;

	qreal factor = matrix().scale(scaleFactor, scaleFactor).mapRect(QRectF(0, 0, 1, 1)).width();
	//qDebug() << "Scale factor:" <<factor;
	if (factor < 0.001 || factor > 100)
		return;

	m_scaleFactor *= scaleFactor;

	scale(scaleFactor, scaleFactor);
	
	updateViewportLayout();
}

void WorkspaceGraphicsView::showEvent(QShowEvent *)
{
	updateViewportLayout();
}


void WorkspaceGraphicsView::mouseMoveEvent(QMouseEvent * mouseEvent)
{
//	qobject_cast<MapGraphicsScene*>(scene())->invalidateLongPress(mapToScene(mouseEvent->pos()));

	updateViewportLayout();
	
	QGraphicsView::mouseMoveEvent(mouseEvent);
}

void WorkspaceGraphicsView::updateViewportLayout()
{
	m_viewportLayout->update();
}

void WorkspaceGraphicsView::setStatusMessage(QString msg)
{
	if(msg.isEmpty())
	{
		m_statusLabel->setPixmap(QPixmap());
		m_statusLabel->hide();
		return;
	}

	m_statusLabel->show();

	if(Qt::mightBeRichText(msg))
	{
		QTextDocument doc;
		doc.setHtml(msg);
		msg = doc.toPlainText();
	}
	
	QImage tmp(1,1,QImage::Format_ARGB32_Premultiplied);
	QPainter tmpPainter(&tmp);

	QFont font("");//"",  20);
	tmpPainter.setFont(font);
	
	QRectF maxRect(0, 0, (qreal)width(), (qreal)height() * .25);
	QRectF boundingRect = tmpPainter.boundingRect(maxRect, Qt::TextWordWrap | Qt::AlignHCenter, msg);
	boundingRect.adjust(0, 0, tmpPainter.font().pointSizeF() * 3, tmpPainter.font().pointSizeF() * 1.25);

	QImage labelImage(boundingRect.size().toSize(), QImage::Format_ARGB32_Premultiplied);
	memset(labelImage.bits(), 0, labelImage.byteCount());
	
	QPainter p(&labelImage);

	QColor bgColor(0, 127, 254, 180);

#ifdef Q_OS_ANDROID
	bgColor = bgColor.lighter(300);
#endif
	
	p.setPen(QPen(Qt::white, 2.5));
	p.setBrush(bgColor);
	p.drawRoundedRect(labelImage.rect().adjusted(0,0,-1,-1), 3., 3.);

	QImage txtImage(boundingRect.size().toSize(), QImage::Format_ARGB32_Premultiplied);
	memset(txtImage.bits(), 0, txtImage.byteCount());
	QPainter tp(&txtImage);
	
	tp.setPen(Qt::white);
	tp.setFont(font);
	tp.drawText(QRectF(QPointF(0,0), boundingRect.size()), Qt::TextWordWrap | Qt::AlignHCenter | Qt::AlignVCenter, msg);
	tp.end();

	//double ss = 8.;
	//p.drawImage((int)-ss,(int)-ss, ImageUtils::addDropShadow(txtImage, ss));
	
	p.end();

#ifdef Q_OS_ANDROID
	m_statusLabel->setPixmap(QPixmap::fromImage(labelImage));
#else
	//m_statusLabel->setPixmap(QPixmap::fromImage(ImageUtils::addDropShadow(labelImage, ss)));
	m_statusLabel->setPixmap(QPixmap::fromImage(labelImage));
#endif
}

/// End WorkspaceGraphicsView implementation
