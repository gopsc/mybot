/* fft1m1.c: example of fast Fourier transform base on 2 for
 * one dimensional complex array, direct and inverse,
 * This program is contribuited by Jiang Yong, 2003. 1.   */
#define N 1024
#include "fft1.c"
void functf(double A[2][N]);
void main(void)
{
  unsigned long int i;
  static double A[2][N];
  FILE *fp;
  fp=fopen("fft1m1.d", "w");
  system("clear");
  functf(A);
  fprintf(fp, "The original data, Ak:\n");
  printf("The original data, Ak:\n");
  for(i=0;i<N;i++) {
    //printf("%d\n", i);
    fprintf(fp,"%4lu:%15.9f %15.9ei\n",i, A[0][i],A[1][i]); }
  printf("fft start.\n");
  fft1(A,1);
  fprintf(fp,"FFT, direct transform ( Ak -> xj ), xj: \n");
  printf("FFT, direct transform ( Ak -> xj ), xj: \n");
  for(i=0;i<N;i++)
    fprintf(fp,"%4lu: %15.9f %15.9ei\t-> %lf\n",i, A[0][i], A[1][i], sqrt(pow(A[0][i],2) + pow(A[1][i],2))/N);
  fft1(A, -1);
  fprintf(fp, "iFFT, inverse transform (x -> A), Ak:\n");
  printf("iFFT, inverse transform (x -> A), Ak:\n");
  for(i=0;i<N;i++)
    fprintf(fp,"%4lu: %15.9f %15.9ei\n",i,A[0][i],A[1][i]);
  fclose(fp);
  printf("OK!\n");
}
/**************************************/
void functf(double A[2][N])
{
    unsigned long int i;
    double dt, t;
    double frequency = 1.0;  // 正弦波频率，单位：Hz
    double amplitude = 1.0;  // 正弦波振幅
    
    dt = 1.0/ N;  // 时间间隔
    
    for(i = 0; i < N; i++)
    {
        t = (double)i * dt;  // 当前时间点
        // 生成正弦波：A*sin(2πft)
        A[0][i] = amplitude * cos(2 * M_PI * frequency * t);
        // 可以在第二行存储余弦波，作为示例
        A[1][i] = amplitude * sin(2 * M_PI * frequency * t);
        //A[1][i] = 0.0;
    }
}
void myfunctf(double A[2][N])
{
  unsigned long int i;
  double dt, tt, A0, A1;
  dt=0.1;
  tt=(double)N*dt;
  A0=exp(-tt);
  for(i=0;i<N;i++)
    { tt=(double)i*dt;
      A1=exp(-tt);
      A[0][i]=(A1+A0/A1)*dt;
      A[1][i]=0.0;  }
}
