FROM fredmajor/perlybase:latest
RUN git clone https://github.com/fredmajor/Beerhunter.git
WORKDIR Beerhunter/Shotgun/rbData
RUN carton install
EXPOSE 3000
ENTRYPOINT ["carton", "exec", "perl", "./rbDataApi.pl", "daemon" ]
CMD [ "--mongohost=localhost" ]
