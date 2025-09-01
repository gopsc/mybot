 /* fft1.c: fast Fourier transform base on 2 for one dimensional
  * complex array, direct and inverse,
  * This program is contribuited by Jiang Yong, 2003. 1. */

 #include <stdio.h>
 #include <stdlib.h>
 #include <math.h>
 
#ifndef DN
#define DN 4
#endif
#define eps 1.0e-9
void initial(void);
void fft1(double A[2][N], int ifft);
unsigned long int inverseq(unsigned long int i1,
                              unsigned long int imax);
void fft1r2(double A[2][N], double B[2][N], int ifft);
void fft1r1(double A[2][DN], int ifft);
static int ifirst = 0, sign = -1;
static unsigned M, jup[16], kup[16];
static double pi, wr[N], wi[N];
/********* initial: *********/
void initial(void)
{
  unsigned long int i, j, ni;
  double unit, tt;
  ni=N;
  M=0;
  while(ni>1) { ni=ni/2; M=M+1; }
  ni=1;
  for(j=0;j<M;j++) ni=ni*2;
  if ((ni-N) != 0)
    {printf("N isn't compatible!\nStrike any key to exit!\n");
    getchar(); exit(1);}
  kup[0]=N/2; /* kup[l]=2^(M-l-1) */
  jup[0]=1;
  for(j=1;j<M;j++)
    { kup[j]=kup[j-1]/2;
      jup[j]=jup[j-1]*2;  }
  pi=4.0*atan((double)1.0);
  unit=2.0*pi/((double)N);
  tt=0.0;
  for(i=0;i<N;i++)
    { wr[i]=cos(tt);
      wi[i]=sign*sin(tt);
      tt=tt+unit; }
}
/** ifft=1 <--> FFT ** ifft =-1 <--> IFFT **/
void fft1(double A[2][N], int ifft)
{
  unsigned long int l, k, i, j, jl0, jl0k, jl1k, reseq, ij;
  double wrc, wis, ar, ai, x[2][N];
  if (ifirst==0) { initial(), ifirst=1; }
  if (ifft==-1)
    for(i=0;i<N;i++) A[1][i]=-A[1][i];
  for(l=0;l<M;l++)
    {
    for (j=0;j<jup[l];j++)
      {
      reseq=inverseq(j,l);
      ij=kup[l]*reseq;
      jl0=2*kup[l]*j;
      wrc=wr[ij];
      wis=wi[ij];
      for(k=0;k<kup[l];k++)
        { jl0k=jl0+k;
          jl1k=jl0+kup[l]+k;
          ar=A[0][jl1k]*wrc-A[1][jl1k]*wis;
          ai=A[0][jl1k]*wis+A[1][jl1k]*wrc;
          A[0][jl1k]=A[0][jl0k]-ar;
          A[1][jl1k]=A[1][jl0k]-ai;
          A[0][jl0k]=A[0][jl0k]+ar;
          A[1][jl0k]=A[1][jl0k]+ai; }
      }
    }
  for(i=0;i<N;i++)
    { j=inverseq(i,M);
      x[0][i]=A[0][j];
      x[1][i]=A[1][j];  }
  for(i=0;i<N;i++)
    { A[0][i]=x[0][i];
      A[1][i]=x[1][i];  }
  if( ifft==-1 )
    for(i=0;i<N;i++)
      { A[0][i]= A[0][i]/((double)N);
          A[1][i]=-A[1][i]/((double)N); }
}
/************************************/
unsigned long int inverseq( unsigned long int i1,
                                      unsigned long int imax )
{
unsigned long int j, ii, i0, inv;
i0=i1;
inv=0;
for (j=0;j<imax;j++)
  { ii=i0%2;
    inv=2*inv+ii;
    i0=(i0-ii)/2; }
return(inv);
}
  
/* ifft=1 <--> FFT ** ifft=-1 <--> IFFT */
void fft1r2(double A[2][N], double B[2][N], int ifft)
{
unsigned long int k, j;
double norm, c[2][N];
if(ifft!=-1)
  {
    for(k=0;k<N;k++)
      { c[0][k]=A[0][k];
        c[1][k]=B[0][k];  }
    fft1( c, 1 );
    A[0][0]=c[0][0];
    A[1][0]=0.0;
    B[0][0]=c[1][0];
    B[1][0]=0.0;
    for(j=1;j<N;j++)
      { A[0][j]= 0.5 * (c[0][j]+c[0][N-j]);
        A[1][j]= 0.5 * (c[1][j]-c[1][N-j]);
        B[0][j]= 0.5 * (c[1][j]+c[1][N-j]);
        B[1][j]=-0.5 * (c[0][j]+c[0][N-j]); }
  } /* end if */
else
  {
  for (j=0;j<N/2;j++)
    /* check {xj}, {yj} is to real {Ak}, {Bk} */
    {
    if(j==0) norm=2.0*fabs(A[1][0])
                  +2.0*fabs(B[1][0]);
    else norm=fabs(A[1][j]+A[1][N-j])
                  +fabs(A[0][j]-A[0][N-j])
                  +fabs(B[1][j]+B[1][N-j])
                  +fabs(B[0][j]-B[0][N-j]);
    if( norm > eps )
      { printf("The IDFT if the series isn't real!\n");
        printf("Strike any key to exit.\n");
        getchar();  exit(0);  }
    }
  for(k=0;k<N;k++)
    { A[0][k]=c[0][k];
      B[0][k]=c[1][k];
      A[1][k]=0.0;
      B[1][0]=0.0;  }
  } /* end else */
}
/* ifft=1 <--> FFT ** ifft=-1 <--> IFFT */
void fft1r1(double A[2][DN], int ifft)
{
  unsigned long int j,k,dk;
  double norm,c[2][N],d[2][N],tt,hunit,cosj,sinj;
  hunit=4.0*atan(1.0)/(double)N;
  if(ifft!=-1)
    {
      for(k=0;k<N;k++)
        { dk=k+k;
          c[0][k]=A[0][dk];
          d[0][k]=A[0][dk+1];
          c[1][k]=0.0;
          d[1][k]=0.0;  }
      fft1r2(c,d,1);
      for(j=0;j<N;j++)
        { tt=(double)j*hunit;
          cosj=cos(tt);
          sinj=sign*sin(tt);
          A[0][j]=c[0][j]+cosj*d[0][j]-sinj*d[1][j];
          A[1][j]=c[1][j]+cosj*d[1][j]+sinj*d[0][j];  }
      A[0][N]=c[0][0]-d[0][0];
      A[1][N]=c[1][0]-d[1][0];
      for(j=1;j<N;j++)
        { A[0][DN-j]=A[0][j];
          A[1][DN-j]=-A[1][j];  }
    } /* end if */
  else
    {
      for(j=0;j<N;j++)  /* check {xj} is to real {Ak} */
        {
          if(j==0) norm=2.0*fabs(A[1][0]);
          else norm=fabs(A[1][j]+A[1][DN-j])+
                    fabs(A[0][j]-A[0][DN-j]);
          if(norm>eps)
            { printf("The IDFT of the series {xj} isn't read!\n");
              printf("Strike any key to exit.\n");
              getchar(); exit(0); }
        }
      for(j=0;j<N;j++)
        { c[0][j]=0.5*(A[0][j]+A[0][N+j]);
          c[1][j]=0.5*(A[1][j]+A[1][N+j]);
          tt=(double)j*hunit;
          cosj=cos(tt);
          sinj=-sign*sin(tt);
          d[0][j]=0.5*(cosj*(A[0][j]-A[0][N+j])
                  -sinj*(A[1][j]-A[1][N+j]));
          d[0][j]=0.5*(cosj*(A[1][j]-A[1][N+j])
                  +sinj*(A[0][j]-A[0][N+j])); }
      fft1r2(c,d,-1);
      for(k=0;k<N;k++)
        { dk=k+k;
          A[0][dk]=c[0][k];
          A[0][dk+1]=c[0][k];
          A[1][dk]=0.0;
          A[1][dk+1]=0.0; }
    } /* and else */
}
