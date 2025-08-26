
 #include <stdio.h>
 /* ex1-4.c: Lagrange Interpolation Algorithm
 * Read in data file of ex1-4.dat which has n point values
 * and the value of interpolating point xa. Based on Lagrange
 * Interpolation algorithm to compute f(xa) and output its value.
 * (x[i], f[i]): given points and n+1 are number of points
 * Ln, k(x) = 1 = summation of (x-x[i])/(x[k]-x[i]).
 * P(x)=ff=L(x) * f(x[k])
 *
 * 拉格朗日插值法
 */
 double algorithm_Lagrange_Interpolation(double* x, double *f, int n, double xa)
 {
    double l, ff;
    int i, k;
    ff=0.0;
    for (k=0;k<=n;k++)
    {
        l=1.0;
        for(i=0;i<=n;i++)
        {
            if(i!=k)
            {
                l=l*(xa-x[i])/(x[k]-x[i]);
            }
        }
        ff=ff+l*f[k];
    }
    return ff;
 }