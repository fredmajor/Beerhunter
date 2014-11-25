FROM fredmajor/perlybase:latest
RUN git clone https://github.com/fredmajor/Beerhunter.git
WORKDIR Beerhunter/Shotgun/rbGet
RUN cpanm Alien::Tidyp
RUN carton install
ENTRYPOINT carton exec "perl RateBeerWorker.pl"
CMD ["--rbdataApiUrl=dev.beerhunter.pl", "--batchsize=20"]
