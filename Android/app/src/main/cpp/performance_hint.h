#pragma once
#include <android/api-level.h>
#include <dirent.h>
#include <dlfcn.h>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <time.h>
#include <vector>

// Android Dynamic Performance Framework (ADPF) for the guest's vCPU threads.
// Each published guest frame reports the vCPU CPU time it took against a
// 60 Hz target, so the platform raises those threads' clocks and core
// placement while the guest falls behind, the way games are meant to ask for
// performance instead of pinning cores. A guest that idles reports small
// durations and is left alone. The NDK API is API 33+ and resolved at run
// time (minSdk is 29); without it, or where the power HAL has no hint
// sessions, this does nothing. Only the frame publisher thread calls it.
class VcpuPerformanceHint {
public:
    void framePublished() {
        if(failed_)return;
        if(!session_ && !open())return;
        // The GL worker ("gles-gl") starts with the guest's first GL call, after the session.
        if(!has_gl_ && set_threads_ && ++frames_%120==0) {
            size_t n=tids_.size();
            findVcpus();
            if(tids_.size()>n){set_threads_(session_,tids_.data(),tids_.size());last_=-1;}
        }
        int64_t cpu=vcpuCpuNs();
        if(cpu<0)return;
        if(last_>=0 && cpu>last_)report_(session_,cpu-last_);
        last_=cpu;
    }
private:
    struct Manager; struct Session;
    using GetManager=Manager *(*)();
    using Create=Session *(*)(Manager *,const int32_t *,size_t,int64_t);
    using Report=int (*)(Session *,int64_t);
    using SetThreads=int (*)(Session *,const int32_t *,size_t);
    static constexpr int64_t kTargetNs=16666667;

    bool open() {
        // Retried until QEMU has created and named its vCPU threads.
        const char *mode=getenv("LT_ADPF");  // "off" for A/B measurements
        if(android_get_device_api_level()<33 || (mode && !strcmp(mode,"off"))){failed_=true;return false;}
        if(!report_) {
            // Keep libandroid loaded for the process lifetime. getManager may start a binder thread; unloading the
            // library when the HAL has no sessions can leave that thread locking a destroyed mutex during boot.
            android_library_=dlopen("libandroid.so",RTLD_NOW|RTLD_LOCAL);
            auto manager=android_library_?reinterpret_cast<GetManager>(dlsym(android_library_,"APerformanceHint_getManager")):nullptr;
            create_=android_library_?reinterpret_cast<Create>(dlsym(android_library_,"APerformanceHint_createSession")):nullptr;
            report_=android_library_?reinterpret_cast<Report>(dlsym(android_library_,"APerformanceHint_reportActualWorkDuration")):nullptr;
            set_threads_=android_library_?reinterpret_cast<SetThreads>(dlsym(android_library_,"APerformanceHint_setThreads")):nullptr;
            manager_=manager?manager():nullptr;
            if(!manager_ || !create_ || !report_){failed_=true;return false;}
        }
        if(tids_.empty())findVcpus();
        if(tids_.empty())return false;
        session_=create_(manager_,tids_.data(),tids_.size(),kTargetNs);
        if(!session_)failed_=true;  // the power HAL has no hint sessions
        return session_!=nullptr;
    }
    void findVcpus() {
        tids_.clear();
        DIR *tasks=opendir("/proc/self/task");
        if(!tasks)return;
        while(dirent *task=readdir(tasks)) {
            char path[64],name[32]={};
            snprintf(path,sizeof path,"/proc/self/task/%s/comm",task->d_name);
            if(FILE *f=fopen(path,"re")){if(!fgets(name,sizeof name,f))name[0]=0;fclose(f);}
            size_t n=strcspn(name,"\n");name[n]=0;
            if(!strncmp(name,"CPU ",4) && n>4 && !strcmp(name+n-4,"/TCG"))tids_.push_back(atoi(task->d_name));
            if(!strcmp(name,"gles-gl")){tids_.push_back(atoi(task->d_name));has_gl_=true;}
        }
        closedir(tasks);
    }
    int64_t vcpuCpuNs() const {
        // Linux per-thread CPU clock of another thread in this process
        // (MAKE_THREAD_CPUCLOCK(tid, CPUCLOCK_SCHED)).
        int64_t total=0;
        for(int32_t tid:tids_) {
            timespec value{};
            if(clock_gettime(clockid_t((~unsigned(tid)<<3)|6),&value)!=0)return -1;
            total+=int64_t(value.tv_sec)*1000000000+value.tv_nsec;
        }
        return total;
    }
    void *android_library_=nullptr;  // intentionally not dlclosed; libandroid's hint binder thread may outlive this call
    Manager *manager_=nullptr;
    Create create_=nullptr;
    Report report_=nullptr;
    SetThreads set_threads_=nullptr;
    unsigned frames_=0;
    bool has_gl_=false;
    Session *session_=nullptr;
    std::vector<int32_t> tids_;
    int64_t last_=-1;
    bool failed_=false;
};
