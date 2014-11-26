FROM fredmajor/perlybase:latest
RUN echo "hi"
RUN git clone https://github.com/fredmajor/Beerhunter.git
WORKDIR Beerhunter/Shotgun/rbData
RUN carton install
ENTRYPOINT ["carton", "exec", "hypnotoad", "-f", "./rbDataApi.pl"]
CMD ["--mongohost=dev.beerhunter.pl"]
