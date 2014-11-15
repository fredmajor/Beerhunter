# This software is Copyright (c) 2014 by Chris Weyl &lt;chris.weyl@wps.io&gt;
#
# This work is licensed under a Creative Commons Attribution-ShareAlike 4.0
# International License (CC-BY-SA-4.0).
#
# http://creativecommons.org/licenses/by-sa/4.0/

FROM rsrchboy/perlbrew-base:latest
MAINTAINER Fred Major major.freddy@yahoo.com

RUN rm /bin/sh && ln -s /bin/bash /bin/sh
ENV TARGET_PERL_FULL stable
ENV TARGET_PERL      stable_threads

RUN perlbrew install  --thread --as $TARGET_PERL $TARGET_PERL_FULL  && rm -rf /usr/local/perlbrew/build/*

RUN perlbrew switch $TARGET_PERL

ENV PATH /usr/local/perlbrew/perls/$TARGET_PERL/bin:$PATH
ENV MANPATH /usr/local/perlbrew/perls/$TARGET_PERL/man
ENV PERLBREW_MANPATH /usr/local/perlbrew/perls/$TARGET_PERL/man
ENV PERLBREW_PATH /usr/local/perlbrew/bin:/usr/local/perlbrew/perls/$TARGET_PERL/bin
ENV PERLBREW_PERL $TARGET_PERL

RUN cpanm Carton
RUN git clone https://github.com/fredmajor/Beerhunter.git
WORKDIR Beerhunter/code/BeerData
RUN apt-get update &&  apt-get -y install  pkg-config  libcurl4-gnutls-dev
RUN cpanm ExtUtils::PkgConfig
# RUN cpanm  Net::Curl
# RUN cpanm YADA

RUN carton install

RUN perlbrew info
RUN perl -v
RUN pwd

