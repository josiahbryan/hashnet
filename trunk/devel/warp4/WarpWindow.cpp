#include "WarpWindow.h"

#ifdef OPENCV_ENABLED
#include <opencv/cv.h>
#endif

class WarpTri {
	public:
	WarpTri(QPointF _p1, QPointF _p2, QPointF _p3,  QPointF _t1, QPointF _t2, QPointF _t3)
		: p1(_p1), p2(_p2), p3(_p3)
		, t1(_t1), t2(_t2), t3(_t3) {}
		
	QPointF p1, p2, p3;
	QPointF t1, t2, t3;
};

QImage warpImage(QImage source, QRect sourceRect, QPolygonF destPoly)
{
	if(sourceRect.isNull())
		sourceRect = source.rect();

	if(source.format() != QImage::Format_ARGB32)
		source = source.convertToFormat(QImage::Format_ARGB32);

	QRect outRect = destPoly.boundingRect().toRect();
	#ifdef DEBUG_WARPIMAGE
	qDebug() << "warpImage(): outRect:"<<outRect<<", bottomRight:"<<outRect.bottomRight()<<", source.size():"<<source.size();
	#endif
	if(outRect.x()      < 0 ||
	   outRect.y()      < 0 ||
	   outRect.right()  > source.width() ||
	   outRect.bottom() > source.height())
	{
		int x = qMin(0, outRect.x());
		int y = qMin(0, outRect.y());
		int w = qMax(source.width()  + abs(x), outRect.right()  + abs(x));
		int h = qMax(source.height() + abs(y), outRect.bottom() + abs(y));
		QRect copyRect(x,y,w,h);
		source = source.copy(copyRect);

		if(x < 0 || y < 0)
		{
			int x1 = abs(x),
			    y1 = abs(y);
			sourceRect.translate(x1, y1);
			destPoly.translate((qreal)x1, (qreal)y1);
		}

		#ifdef DEBUG_WARPIMAGE
		qDebug() << "warpImage(): outRect: "<<outRect<<" either <0 or >image bounds, copyRect:"<<copyRect<<", sourceRect:"<<sourceRect<<", destPoly:"<<destPoly;
		#endif
	}

	#ifdef DEBUG_WARPIMAGE
	qDebug() << "warpImage(): sourceRect: "<<sourceRect<<", destPoly: "<<destPoly;
	qDebug() << "warpImage(): source.rect(): "<<source.rect();
	#endif

	QImage outImg(source.size(), QImage::Format_ARGB32_Premultiplied);
	memset(outImg.bits(), 0, outImg.byteCount());
	QPainter p(&outImg);

	// The following 'for' loop from http://stackoverflow.com/questions/4774172/image-manipulation-and-texture-mapping-using-html5-canvas
	//int tris[][] = {{0, 1, 2}, {2, 3, 0}}; // Split in two triangles

	QList<WarpTri> tris;

	tris << WarpTri( destPoly[0], destPoly[1], destPoly[2],
			 sourceRect.topLeft(),
			 sourceRect.topRight(),
			 sourceRect.bottomRight() );

	tris << WarpTri( destPoly[2], destPoly[3], destPoly[0],
			 sourceRect.bottomRight(),
			 sourceRect.bottomLeft(),
			 sourceRect.topLeft() );
			 
	for (int t=0; t<2; t++)
	{
		p.save();

		WarpTri tri = tris[t];
		double x0 = tri.p1.x(), x1 = tri.p2.x(), x2 = tri.p3.x();
		double y0 = tri.p1.y(), y1 = tri.p2.y(), y2 = tri.p3.y();
		double u0 = tri.t1.x(), u1 = tri.t2.x(), u2 = tri.t3.x();
		double v0 = tri.t1.y(), v1 = tri.t2.y(), v2 = tri.t3.y();

		// Set clipping area so that only pixels inside the triangle will
		// be affected by the image drawing operation
		QPainterPath path;
			path.moveTo(x0, y0);
			path.lineTo(x1, y1);
			path.lineTo(x2, y2);
		p.setClipPath(path);

		// Compute matrix transform
		double delta = u0*v1 + v0*u2 + u1*v2 - v1*u2 - v0*u1 - u0*v2;
		double delta_a = x0*v1 + v0*x2 + x1*v2 - v1*x2 - v0*x1 - x0*v2;
		double delta_b = u0*x1 + x0*u2 + u1*x2 - x1*u2 - x0*u1 - u0*x2;
		double delta_c = u0*v1*x2 + v0*x1*u2 + x0*u1*v2 - x0*v1*u2
			- v0*u1*x2 - u0*x1*v2;
		double delta_d = y0*v1 + v0*y2 + y1*v2 - v1*y2 - v0*y1 - y0*v2;
		double delta_e = u0*y1 + y0*u2 + u1*y2 - y1*u2 - y0*u1 - u0*y2;
		double delta_f = u0*v1*y2 + v0*y1*u2 + y0*u1*v2 - y0*v1*u2
			- v0*u1*y2 - u0*y1*v2;

		// Draw the transformed image
		p.setTransform(QTransform(delta_a/delta, delta_d/delta,
			delta_b/delta, delta_e/delta,
			delta_c/delta, delta_f/delta));
		p.drawImage(0, 0, source);
		p.restore();
	}

	p.end();
	
	return outImg;

	

	//we need our points as opencv points
	//be nice to do this without opencv?
	CvPoint2D32f cvsrc[4];
	CvPoint2D32f cvdst[4];

	// Warp source coordinates
	cvsrc[0].x = sourceRect.left();
	cvsrc[0].y = sourceRect.top();
	cvsrc[1].x = sourceRect.right();
	cvsrc[1].y = sourceRect.top();
	cvsrc[2].x = sourceRect.right();
	cvsrc[2].y = sourceRect.bottom();
	cvsrc[3].x = sourceRect.left();
	cvsrc[3].y = sourceRect.bottom();

	// Warp destination coordinates
// 	cvdst[0].x = sourceRect.left()	+ 25;
// 	cvdst[0].y = sourceRect.top()	+ 25;
//
// 	cvdst[1].x = sourceRect.right()	- 50;
// 	cvdst[1].y = sourceRect.top()	+ 50;
//
// 	cvdst[2].x = sourceRect.right()	- 75;
// 	cvdst[2].y = sourceRect.bottom()- 75;
//
// 	cvdst[3].x = sourceRect.left()	+ 100;
// 	cvdst[3].y = sourceRect.bottom()- 100;

// 	cvdst[0].x = sourceRect.left()	+ 0;
// 	cvdst[0].y = sourceRect.top()	+ 0;
//
// 	cvdst[1].x = sourceRect.right()	- 0;
// 	cvdst[1].y = sourceRect.top()	+ 0;
//
// 	cvdst[2].x = sourceRect.right()	- 0;
// 	cvdst[2].y = sourceRect.bottom()- 0;
//
// 	cvdst[3].x = sourceRect.left()	+ 0;
// 	cvdst[3].y = sourceRect.bottom()- 0;

	cvdst[0].x = destPoly[0].x(); // left
	cvdst[0].y = destPoly[0].y(); // top

	cvdst[1].x = destPoly[1].x(); // right
	cvdst[1].y = destPoly[1].y(); // top

	cvdst[2].x = destPoly[2].x(); // right
	cvdst[2].y = destPoly[2].y(); // bottom

	cvdst[3].x = destPoly[3].x(); // left
	cvdst[3].y = destPoly[3].y(); // bottom

	//we create a matrix that will store the results
	//from openCV - this is a 3x3 2D matrix that is
	//row ordered
	CvMat * translate = cvCreateMat(3,3,CV_32FC1);

	//this is the slightly easier - but supposidly less
	//accurate warping method
	//cvWarpPerspectiveQMatrix(cvsrc, cvdst, translate);

	//for the more accurate method we need to create
	//a couple of matrixes that just act as containers
	//to store our points  - the nice thing with this
	//method is you can give it more than four points!
	CvMat* src_mat = cvCreateMat( 4, 2, CV_32FC1 );
	CvMat* dst_mat = cvCreateMat( 4, 2, CV_32FC1 );

	//copy our points into the matrixes
	cvSetData( src_mat, cvsrc, sizeof(CvPoint2D32f));
	cvSetData( dst_mat, cvdst, sizeof(CvPoint2D32f));

	//qDebug() << "warpImage(): cvFindHomography ...";
	
	//figure out the warping!
	//warning - older versions of openCV had a bug
	//in this function.
	cvFindHomography(src_mat, dst_mat, translate);

	//get the matrix as a list of floats
	//float *matrix = translate->data.fl;

	//imageTmp = QImage((const uchar*)curFrame->pointer(),curFrame->size().width(),curFrame->size().height(),QImage::Format_RGB32);

	//qDebug() << "warpImage(): Creating input IplImage...";
	IplImage* frame = 0;
	frame = cvCreateImageHeader( cvSize(source.width(), source.height()), IPL_DEPTH_8U, 4);
	frame->imageData = (char*) source.bits();

	//qDebug() << "warpImage(): Creating output IplImage...";
	IplImage *frameOut;
	frameOut = cvCreateImageHeader( cvSize(source.width(), source.height()), IPL_DEPTH_8U, 4);
	frameOut->imageData = (char*) malloc( source.byteCount() );

	//qDebug() << "warpImage(): Creating output cvWarpPerspective...";
	cvWarpPerspective(frame, frameOut, translate);

	//qDebug() << "warpImage(): Copying imageOut...";
	QSize outSize = source.size();
	//qDebug() << "debug: "<<destPoly.boundingRect();//.size().toSize();
	QImage imageOut( (uchar*)frameOut->imageData, outSize.width(), outSize.height(), source.format() );
	QImage dest = imageOut.copy();

	free(frameOut->imageData);
	cvReleaseImageHeader(&frameOut);
	cvReleaseImageHeader(&frame);

	//QImage img = IplImage2QImage(frameOut);

	//we need to copy these values
	//from the 3x3 2D openCV matrix which is row ordered
	//
	// ie:   [0][1][2] x
	//       [3][4][5] y
	//       [6][7][8] w

	//to openGL's 4x4 3D column ordered matrix
	//        x  y  z  w
	// ie:   [0][3][ ][6]   [1-4]
	//       [1][4][ ][7]   [5-8]
	//	 [ ][ ][ ][ ]   [9-12]
	//       [2][5][ ][9]   [13-16]
	//


// 	m_warpMatrix[0][0] = matrix[0];
// 	m_warpMatrix[0][1] = matrix[3];
// 	m_warpMatrix[0][2] = 0.;
// 	m_warpMatrix[0][3] = matrix[6];
//
// 	m_warpMatrix[1][0] = matrix[1];
// 	m_warpMatrix[1][1] = matrix[4];
// 	m_warpMatrix[1][2] = 0.;
// 	m_warpMatrix[1][3] = matrix[7];
//
// 	m_warpMatrix[2][0] = 0.;
// 	m_warpMatrix[2][1] = 0.;
// 	m_warpMatrix[2][2] = 0.;
// 	m_warpMatrix[2][3] = 0.;
//
// 	m_warpMatrix[3][0] = matrix[2];
// 	m_warpMatrix[3][1] = matrix[5];
// 	m_warpMatrix[3][2] = 0.;
// 	m_warpMatrix[3][3] = matrix[8];

	cvReleaseMat(&translate);
	cvReleaseMat(&src_mat);
	cvReleaseMat(&dst_mat);

	return dest;
}


WarpWindow::WarpWindow()
{
	m_subdivClick = false;
	m_mouseDown = false;
	
	m_image = QImage("tex.jpg").scaled(320,240);
	resize(m_image.size());

	QImage source = m_image;
	double xgrid = 1.;
	double ygrid = 1.;
	double xstep = ((double)source.width())  / xgrid;
	double ystep = ((double)source.height()) / ygrid;

	int counter = 0;
	for(double x=0; x<source.width(); x+=xstep)
	{
		for(double y=0; y<source.height(); y+=ystep)
		{
			QRect sourceRect(x,y,xstep,ystep);

			QPolygonF destPoly;

			destPoly << QPointF(x,y - 100); //sourceRect.topLeft();
			destPoly << QPointF(x+xstep,y - 100); //sourceRect.topRight();
			destPoly << QPointF(x+xstep,y+ystep); //sourceRect.bottomRight();
			destPoly << QPointF(x,y+ystep); //sourceRect.bottomLeft();

// 			if(counter == 0)
// 				destPoly[1] = QPointF(x+xstep,y-150);
// 			else
// 			if(counter == 2)
// 				destPoly[0] = QPointF(x,y-150);

// 			destPoly = QPolygonF()
// 				<<  QPointF(50, 125)
// 				<< QPointF(490, 25)
// 				//<< QPointF(1149, 474)
// 				<< QPointF(726, 332)
// 				<< QPointF(120, 410);

 			destPoly = QPolygonF();
/*			destPoly <<  QPointF(10.9101, 8.62241) ;
			destPoly <<  QPointF(267.037, -41.3776) ;
			destPoly <<  QPointF(256, 190) ;
			destPoly <<  QPointF(-52.0899, 199.305) ;*/

// 			destPoly <<  QPointF(-154.681, 47.5602) ;
// 			destPoly <<  QPointF(143.543, -16.4398) ;
// 			destPoly <<  QPointF(275, 175.933) ;
// 			destPoly <<  QPointF(-201.681, 229.915) ;

			destPoly <<  QPointF(88, 195) ;
			destPoly <<  QPointF(244, 128) ;
			destPoly <<  QPointF(322, 234) ;
			destPoly <<  QPointF(32, 286) ;


// // 				<< QPointF(24, 208)
// // 				<< QPointF(156, -49)
// // 				<< QPointF(621, 567)
// // 				<< QPointF(120, 410);
// 
// 				<< QPointF(24, 208)
// 				<< QPointF(320, 148)
// 				<< QPointF(451, 326)
// 				<< QPointF(120, 410);
				
			counter ++;
			ImagePoly *data = new ImagePoly(sourceRect, destPoly);
			m_polys << data;
		}
	}

	connect(&m_renderTimer, SIGNAL(timeout()), this, SLOT(render()));
	m_renderTimer.setSingleShot(true);
	m_renderTimer.setInterval(10);

	render();
}

#define DEBUG_RENDER

void WarpWindow::render()
{
	QImage source = m_image;
	//double power = 3; // 1.8

// 	int xgrid = 2;
// 	int ygrid = 2;
// 	int xstep = source.width() / xgrid;
// 	int ystep = source.height() / ygrid;

	QRectF bounds;
	foreach(ImagePoly *data, m_polys)
		bounds = bounds.united(data->poly.boundingRect());

	double x = bounds.x();
	double y = bounds.y();
	double w = bounds.width();//  + x;
	double h = bounds.height();// + y;

	#ifdef DEBUG_RENDER
	qDebug() << "render(): orig size:" << m_image.size();
	qDebug() << "render(): bounds:"<<bounds;
	#endif
	//QImage output = QImage(QSize(w + fabs(x),h + fabs(y)), source.format());
	//QImage output = QImage(QSize(w + qMinE(0.,x)*-1,h + qMin(0.,y)*-1), source.format());
	QImage output = QImage(bounds.size().toSize(), source.format());
	#ifdef DEBUG_RENDER
	qDebug() << "render(): output size: "<<output.size();
	#endif

	resize(output.width(), output.height());
	
	memset(output.bits(), 0, output.byteCount());
	
	QPainter p(&output);
	//p.translate(qMin(0.,x)*-1, qMin(0.,y)*-1);
	//p.translate( -
	p.translate(- bounds.topLeft());
	//m_boundsTopLeft = bounds.topLeft();
	m_bounds = bounds;

	int counter = 0;
	QList<QColor> color;
	color << Qt::red << Qt::green << Qt::blue << Qt::cyan;

	#if 1
	QList<WarpTri> tris;
	
	QTime t; t.start();
	foreach(ImagePoly *data, m_polys)
	{
		QRect sourceRect = data->rect;
		QPolygonF destPoly = data->poly;

		qDebug() << "render(): sourceRect.topLeft():"<<sourceRect.topLeft();

		QPointF tl = destPoly.boundingRect().topLeft();
		QPointF pnt = QPointF(qMin(0., tl.x()), qMin(0., tl.y()));
		qDebug() << "render(): destPoly.boundingRect().topLeft():"<<destPoly.boundingRect().topLeft();
		qDebug() << "render(): pnt:"<<pnt;
		//p.drawImage(destPoly.boundingRect().topLeft() + QPointF(.5,.5), img);

		//destPoly.translate(-pnt);
		if(sourceRect.isValid())
		{
// 			//destPoly.translate(sourceRect.topLeft() *  1);
// 
// 			p.drawImage(QRectF(img.rect()).translated(pnt).adjusted(2,2,2,2), img);

			//QImage img = warpImage(source.copy(sourceRect), QRect(), destPoly);
			//QImage img = warpImage(source, sourceRect, destPoly);
			//p.drawImage(pnt, img);

			tris.clear();

			tris << WarpTri( destPoly[0], destPoly[1], destPoly[2],
					 sourceRect.topLeft(),
					 sourceRect.topRight(),
					 sourceRect.bottomRight() );

			tris << WarpTri( destPoly[2], destPoly[3], destPoly[0],
					 sourceRect.bottomRight(),
					 sourceRect.bottomLeft(),
					 sourceRect.topLeft() );

			for (int t=0; t<2; t++)
			{
				p.save();
				//p.translate(tris[t].p1);

				WarpTri tri = tris[t];
				double x0 = tri.p1.x(), x1 = tri.p2.x(), x2 = tri.p3.x();
				double y0 = tri.p1.y(), y1 = tri.p2.y(), y2 = tri.p3.y();
				double u0 = tri.t1.x(), u1 = tri.t2.x(), u2 = tri.t3.x();
				double v0 = tri.t1.y(), v1 = tri.t2.y(), v2 = tri.t3.y();

				// Set clipping area so that only pixels inside the triangle will
				// be affected by the image drawing operation
				QPainterPath path;
					path.moveTo(x0, y0);
					path.lineTo(x1, y1);
					path.lineTo(x2, y2);
				p.setClipPath(path);

				// Compute matrix transform
				double delta   = u0*v1 + v0*u2 + u1*v2 - v1*u2 - v0*u1 - u0*v2;
				double delta_a = x0*v1 + v0*x2 + x1*v2 - v1*x2 - v0*x1 - x0*v2;
				double delta_b = u0*x1 + x0*u2 + u1*x2 - x1*u2 - x0*u1 - u0*x2;
				double delta_c = u0*v1*x2 + v0*x1*u2 + x0*u1*v2 - x0*v1*u2
					       - v0*u1*x2 - u0*x1*v2;
				double delta_d = y0*v1 + v0*y2 + y1*v2 - v1*y2 - v0*y1 - y0*v2;
				double delta_e = u0*y1 + y0*u2 + u1*y2 - y1*u2 - y0*u1 - u0*y2;
				double delta_f = u0*v1*y2 + v0*y1*u2 + y0*u1*v2 - y0*v1*u2
					       - v0*u1*y2 - u0*y1*v2;

				// Draw the transformed image
				p.setTransform(QTransform(
					delta_a/delta, delta_d/delta,
					delta_b/delta, delta_e/delta,
					delta_c/delta, delta_f/delta));

				//p.drawImage(-x, -y, source);
				//p.drawImage(0., 0., source);
				//p.drawImage(qMin(x,0.), qMin(y,0.), source);
				//p.drawImage(-1 * pnt, source);
				p.drawImage(- bounds.topLeft(), source);
				p.restore();
			}

			//p.drawImage(QRectF(img.rect()).translated(pnt).adjusted(2,2,2,2), img);
			
		}
	}
	qDebug() << "Total milliseconds to render: "<<t.elapsed() << "ms";
	#endif

	#if 1
	foreach(ImagePoly *data, m_polys)
	{
		p.setPen(color[counter++ % 4]);
		//p.setPen(Qt::white);
		p.drawPolygon(data->poly);
	}
	#endif

// 	p.setPen(Qt::yellow);
// 	p.drawPath(path);


	p.end();

	m_rendered = output;
	update();
}

void WarpWindow::paintEvent(QPaintEvent *)
{
	QPainter p(this);
	p.drawImage(0, 0, m_rendered);
}

void WarpWindow::mousePressEvent(QMouseEvent *e)
{
	QPointF pnt = e->posF();// + m_bounds.topLeft();//m_boundsTopLeft;

	if(m_subdivClick || (e->modifiers() & Qt::ShiftModifier)) //Qt::KeyboardModifier)
	{
		foreach(ImagePoly *data, m_polys)
		{
			if(data->poly.containsPoint(pnt, Qt::OddEvenFill))
			{
				QPolygonF poly = data->poly;

				// Create lines from the points of the poly
				QLineF top(poly[0], poly[1]);
				QLineF right(poly[1], poly[2]);
				QLineF bottom(poly[2], poly[3]);
				QLineF left(poly[3], poly[0]);

				// Calculate the center of the lines and the center of the poly
				QPointF centerTop    = top.pointAt(.5);
				QPointF centerRight  = right.pointAt(.5);
				QPointF centerBottom = bottom.pointAt(.5);
				QPointF centerLeft   = left.pointAt(.5);
				QPointF centerCenter;
				QLineF(centerTop, centerBottom).intersect(QLineF(centerRight, centerLeft), &centerCenter);

				// Subdivide the source rectangle into four polys
				QRect sr = data->rect;
				QSize s2(sr.width()/2, sr.height()/2);
				QPoint sp2(s2.width() + sr.left(), s2.height() + sr.top());
				QRect sourceTopLeft(sr.topLeft(), s2);
				QRect sourceTopRight(QPoint(sp2.x(), sr.top()), s2);
				QRect sourceBottomRight(sp2, s2);
				QRect sourceBottomLeft(QPoint(sr.left(), sp2.y()), s2);
				
				QPolygonF destPoly;

				// Create new top-left poly
				destPoly = QPolygonF()
					<< top.p1()
					<< centerTop
					<< centerCenter
					<< centerLeft;
				m_polys << new ImagePoly(sourceTopLeft, destPoly);

				// Top right poly
				destPoly = QPolygonF()
					<< centerTop
					<< top.p2()
					<< centerRight
					<< centerCenter;
				m_polys << new ImagePoly(sourceTopRight, destPoly);

				// Bottom right poly
				destPoly = QPolygonF()
					<< centerCenter
					<< centerRight
					<< bottom.p1()
					<< centerBottom;
				m_polys << new ImagePoly(sourceBottomRight, destPoly);

				// Bottom left poly
				destPoly = QPolygonF()
					<< centerLeft
					<< centerCenter
					<< centerBottom
					<< bottom.p2();
				m_polys << new ImagePoly(sourceBottomLeft, destPoly);

				// Remove and delete the old poly that covers the four new polys
				//m_polys.removeAll(data);
				//delete data;
					
				if(m_renderTimer.isActive())
					m_renderTimer.stop();

				m_renderTimer.start();

				break;
			}
		}

		return;
	}
	
	m_mouseDown = true;

	//m_startMousePoint = pnt;

	ImagePoly *minPoly;
	QPointF minPnt;
	double minLen = (double)INT_MAX;
	
	foreach(ImagePoly *data, m_polys)
	{
		foreach(QPointF polyPnt, data->poly)
		{
			double len = QLineF(polyPnt, pnt).length();
			if(len < minLen)
			{
				minLen = len;
				minPnt = polyPnt;
				minPoly = data;
			}
		}
	}

	//qDebug() << "Found minPnt "<<minPnt<<", dist:"<<minLen;;

	m_gridPoint = minPnt;
	//m_dragStartPoint = minPnt;
	m_startMousePoint = minPnt;
	m_startBoundsTL = m_bounds.topLeft();
	
	m_selectedPoints.clear();
	foreach(ImagePoly *data, m_polys)
	{
		m_origPolys[data] = data->poly;
		int idx = 0;
		foreach(QPointF polyPnt, data->poly)
		{
			double len = QLineF(polyPnt, minPnt).length();
			if(len < 0.0001)
			{
				m_selectedPoints << PolyPointInfo(&data->poly, idx);
				//qDebug() << "Matched idx "<<idx<<" to "<<minPnt;
			}

			idx ++;
		}
	}
	
}

void WarpWindow::mouseReleaseEvent(QMouseEvent *)
{
	m_mouseDown = false;
}


/// \brief Calculates the weight of point \a o at point \a i given power \a p, used internally by interpolateValue()
#define _dist2(a, b) ( ( ( a.x() - b.x() ) * ( a.x() - b.x() ) ) + ( ( a.y() - b.y() ) * ( a.y() - b.y() ) ) )
//#define NEARBY2 (2000 * 2000)
//#define NEARBY2 (4000 * 4000)
//#define NEARBY2 (1000 * 1000)

inline double weight(QPointF i, QPointF o, double p)
{
	double b = pow(sqrt(_dist2(i,o)),p);
	return b == 0 ? 0 : 1 / b;
}


void WarpWindow::mouseMoveEvent(QMouseEvent *e)
{
	if(m_mouseDown)
	{
		QPointF pnt = e->posF();// + m_bounds.topLeft();// - m_startBoundsTL;//m_boundsTopLeft;
		QPointF delta = pnt - m_startMousePoint; //(m_startMousePoint - m_startBoundsTL + m_bounds.topLeft());
		//qDebug() << "mouseMove(): pnt:" <<pnt<<", delta:"<<delta<<", m_startBoundsTL:"<<m_startBoundsTL<<", m_bounds.topLeft():"<<m_bounds.topLeft()<<", e->posF():"<<e->posF();

		//m_startMousePoint = pnt;
// 		foreach(PolyPointInfo info, m_selectedPoints)
// 		{
// 			QPointF* polyPnt = info.poly->data();
// 			polyPnt[info.point].rx() = pnt.x();
// 			polyPnt[info.point].ry() = pnt.y();
// 			//.rx() = pnt.x();
// 			//info.poly->at(info.point).ry() = pnt.y();
// 
// 			//qDebug() << "mouseMoveEvent(): "<<*(info.poly);
// 		}

		int polyIdx = 0;
		foreach(ImagePoly *data, m_polys)
		{
			//qDebug() << "mouseMove(): polyIdx:"<<polyIdx++;
			int idx = 0;
			foreach(QPointF polyPnt, data->poly)
			{
				double len = QLineF(polyPnt, m_gridPoint).length();
				if(len < 0.0001)
				{
					data->poly[idx] = pnt;
					//qDebug() << "i:"<<idx<<",set to:"<<pnt;
					//m_selectedPoints << PolyPointInfo(&data->poly, idx);
					//qDebug() << "Matched idx "<<idx<<" to "<<minPnt;
					qDebug() << "poly: ";
					foreach(QPointF p, data->poly)
						qDebug() << "destPoly << " << p << ";";
				}
				else
				if(0)
				{
					QPointF origPolyPnt = m_origPolys[data][idx];
					
					QPointF delta2 = polyPnt - pnt; //m_dragStartPoint - origPolyPnt;

					double ndx = fabs(delta2.x()) / m_bounds.width();
					double ndy = fabs(delta2.y()) / m_bounds.height();
					double w = qMax(0.,qMin(1.,sqrt(ndx*ndx + ndy*ndy)));

					//QPointF delta3 = QPointF(delta.x() * ndx, delta.y() * ndy);
					QPointF delta3 = delta * w;

					QPointF newPolyPnt = origPolyPnt - delta3;
					//qDebug() << "i:"<<idx<<",d:"<<delta<<",d2:"<<delta2<<",o:"<<origPolyPnt<<",w:"<<w<<",d3:"<<delta3<<",new:"<<newPolyPnt;

					//double w = weight(pnt, polyPnt, 3);

					//QPointF delta3 = delta ;

					//qDebug() << "delta:"<<delta<<", w:"<<w<<", delta3:"<<delta3;

					data->poly[idx] = newPolyPnt;// + QPointF(delta.x() / delta2.x(), delta.y() / delta2.y());
				}

				idx ++;
			}
		}

		m_gridPoint = pnt;

		//render();
		if(m_renderTimer.isActive())
			m_renderTimer.stop();

		m_renderTimer.start();
	}
}
