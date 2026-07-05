#ifndef GRAPH_H
#define GRAPH_H 
void line(int x0, int y0, int x1, int y1, int color);
void rectangle(int x1, int y1, int x2, int y2, int color, int filled);
unsigned char const *drawvect(int x, int y, unsigned char const *vect, int width, int high, int color);
void drawvfont(int x, int y, wchar_t z, int target_width, int target_height, int color);
#endif
