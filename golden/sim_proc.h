#ifndef SIM_PROC_H
#define SIM_PROC_H

#include <iostream>
#include <stdlib.h>
#include <math.h>
#include <fstream>
#include <iomanip>
#include <string.h>
#include <sstream>
#include <vector>
#include <algorithm>

using namespace std;

typedef struct proc_params
{
    unsigned long int rob_size;
    unsigned long int iq_size;
    unsigned long int width;
} proc_params;

proc_params params;

// Put additional data structures here as per your requirement

int dynamic_instruction_count = 0; // Dynamic Instruction Count
int num_of_cycles = 0; // counting the number of cycles
float instructions_per_cycle = 0; // Instruction Per Cycle (IPC)

int Width;
bool pipeline_empty; // defined to check if the pipeline is empty or not

// unsigned int PC; // PC is the program counter of the instruction

// Operation type
// either 0, 1 or 2
enum operation_type
{
    operation_0 = 0,
    operation_1,
    operation_2,
};

// For calculating the start time at which cycle begins and duration 
typedef struct time_info
{
    int begin_cycle;
    int duration;
} time_info_t;

// determines in which instruction is the pipeline stage in currently
class Instruction_in_pipeline_stage
{
public:
    int seq_number = 0;

    operation_type function_units;
    int src_1 = -1, src_1_orig = -1;
    int src_2 = -1, src_2_orig = -1;
    int dst = -1;
    int PC = 0;
    int count = 0;

    // declared for calculating the duration of each pipeline stage
    time_info_t FE;
    time_info_t DE;
    time_info_t RN;
    time_info_t RR;
    time_info_t DI;
    time_info_t IS;
    time_info_t EX;
    time_info_t WB;
    time_info_t RT;

    bool src1_ready = false;
    bool src2_ready = false;
    bool rs1_ROB = false;
    bool rs2_ROB = false;

    Instruction_in_pipeline_stage() = default;
    Instruction_in_pipeline_stage(const Instruction_in_pipeline_stage &) = default;

    bool operator<(const Instruction_in_pipeline_stage &temp) const
    {
        return PC < temp.PC;
    }
};

// structure for Rename Map Table
typedef struct RMT
{
    int tag;
    bool valid;
} RMT_Table;

// structure for Reorder Buffer
typedef struct ROB
{
    bool ready;
    int dest, pc;

} ROB_Table;

// maintaining the register vector throughout the program
// used for swapping the values of registers between the stages
struct Register_log
{
    bool empty;
    vector<Instruction_in_pipeline_stage> reg;
};

// structure for Reorder Buffer
// initialising the head and tail pointer
// Maintaining a vector of ROB entries
struct ReorderBuffer
{
    int head, tail;
    int size;

    vector<ROB_Table> rob;
};

// main class 
// advances through the different stages of the pipeline
class Out_of_Order_Pipeline
{
public:
    // PIPELINE REGSTERS
    // Different register stages in the out-of-order pipeline
    // Pipeline stages Fetch, Decode, rename, register read, dispatch, issue, execute, writeback and retire
    Register_log DE, RN, RR, DI, WB, RT;
    struct ReorderBuffer reorder_buffer;

    // maintaining the vectors of IQ and EX in pipeline stages
    vector<Instruction_in_pipeline_stage> issue_queue;
    vector<Instruction_in_pipeline_stage> execute_list;
    RMT_Table rename_map_table[67];

    // The 9 stages in the out - of - order pipeline
    bool Advance_Cycle(bool end_of_file);
    bool Fetch(FILE *FP);
    void Decode();
    void Rename();
    void RegRead();
    void Dispatch();
    void Issue();
    void Execute();
    void Writeback();
    void Retire();
};

#endif
