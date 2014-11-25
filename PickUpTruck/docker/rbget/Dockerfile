FROM fredmajor/perlybase:latest
RUN git clone https://github.com/fredmajor/Beerhunter.git
WORKDIR Beerhunter/Shotgun/rbGet
RUN cpanm Alien::Tidyp
RUN carton install
RUN echo 'elo'
