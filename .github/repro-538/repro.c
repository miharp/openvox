#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <netdb.h>
#include <sys/wait.h>
static int look(const char *h){struct addrinfo *r=0;int e=getaddrinfo(h,"443",0,&r);if(r)freeaddrinfo(r);return e;}
int main(int c,char**v){
  const char *h = c>1?v[1]:"github.com";
  look(h);
  int sig=0,ok=0;
  for(int i=0;i<10;i++){
    pid_t p=fork();
    if(!p){ alarm(10); look(h); _exit(0);}
    int st; waitpid(p,&st,0);
    if(WIFSIGNALED(st)) {sig++; fprintf(stderr,"child sig %d\n",WTERMSIG(st));} else ok++;
  }
  printf("ok=%d signaled=%d\n",ok,sig); return 0;}
