FROM rsrchboy/perlbrew-base:latest
MAINTAINER Freddy Major <major.freddy@yahoo.com>

RUN rm /bin/sh && ln -s /bin/bash /bin/sh
RUN perlbrew install -v perl-5.20.1 -Dusethreads --as perl-5.20.1_threads
RUN perlbrew switch perl-5.20.1_threads
RUN cpanm Carton
CMD "echo" "hi Fred!"

