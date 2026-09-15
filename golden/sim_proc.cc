#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <inttypes.h>
#include "sim_proc.h"
#include <iostream>
#include <iomanip>

void print_statistics(proc_params params, char *trace_file);

/*  argc holds the number of command line arguments
    argv[] holds the commands themselves

    Example:-
    sim 256 32 4 gcc_trace.txt
    argc = 5
    argv[0] = "sim"
    argv[1] = "256"
    argv[2] = "32"
    ... and so on
*/
int main(int argc, char *argv[])
{
    FILE *FP;         // File handler
    char *trace_file; // Variable that holds trace file name;
    // proc_params params;  // look at sim_bp.h header file for the the definition of struct proc_params

    // creating an object for the class
    Out_of_Order_Pipeline ooo_schedular;

    if (argc != 5)
    {
        printf("Error: Wrong number of inputs:%d\n", argc - 1);
        exit(EXIT_FAILURE);
    }

    params.rob_size = strtoul(argv[1], NULL, 10);
    params.iq_size = strtoul(argv[2], NULL, 10);
    params.width = strtoul(argv[3], NULL, 10);
    trace_file = argv[4];

    ooo_schedular.reorder_buffer.size = params.rob_size;
    // issue_queue.size = params.iq_size;
    Width = params.width;

    // initialising the global variables
    num_of_cycles = 0;
    dynamic_instruction_count = 0;
    pipeline_empty = false;

    // emptying the register log for the pipeline stages
    ooo_schedular.DE.empty = true;
    ooo_schedular.RN.empty = true;
    ooo_schedular.RR.empty = true;
    ooo_schedular.DI.empty = true;
    ooo_schedular.WB.empty = true;
    ooo_schedular.RT.empty = true;

    // default value of the Head and Tail pointer of the ROB table
    ooo_schedular.reorder_buffer.head = 0;
    ooo_schedular.reorder_buffer.tail = 0;

    // initialising the RMT
    for (int i = 0; i < (int)(sizeof(ooo_schedular.rename_map_table) / sizeof(ooo_schedular.rename_map_table[0])); i++)
    {
        ooo_schedular.rename_map_table[i].valid = false;
        ooo_schedular.rename_map_table[i].tag = -1;
    }

    // Initializing the reorder_buffer
    ROB_Table rb; 
    memset((void *)&rb, 0, sizeof(ROB_Table));

    // rolling back of the head and tail pointer in the ROB table
    for (int i = 0; i < (int)params.rob_size; i++)
    {
        ooo_schedular.reorder_buffer.rob.push_back(rb);
    }

    // printf("rob_size:%lu "
    //        "iq_size:%lu "
    //        "width:%lu "
    //        "tracefile:%s\n",
    //        params.rob_size, params.iq_size, params.width, trace_file);
    // Open trace_file in read mode
    FP = fopen(trace_file, "r");
    if (FP == NULL)
    {
        // Throw error and exit if fopen() failed
        printf("Error: Unable to open file %s\n", trace_file);
        exit(EXIT_FAILURE);
    }
    // cout << " fstream fin;\n" << endl;
    fstream fin;
    fin.open(trace_file, ios::in);

    ///////////////////////////////////////////////////////////////////////////////////////////////////////
    //
    // The following loop just tests reading the trace and echoing it back to the screen.
    //
    // Replace this loop with the "do { } while (Advance_Cycle());" loop indicated in the Project 3 spec.
    // Note: fscanf() calls -- to obtain a fetch bundle worth of instructions from the trace -- should be
    // inside the Fetch() function.
    //
    ///////////////////////////////////////////////////////////////////////////////////////////////////////
    
    // cout << "Before Do While Loop\n" << endl;
    // End of file
    bool eof = false;
    
    // The do-while loop for transitioning between the different stages of the pipeline
    // calling the functions to execute the stages in the pipeline
    do
    {
        // printf("%lx %d %d %d %d\n", pc, op_type, dest, src1, src2); //Print to check if inputs have been read correctly
        ooo_schedular.Retire();
        ooo_schedular.Writeback();
        ooo_schedular.Execute();
        ooo_schedular.Issue();
        ooo_schedular.Dispatch();
        ooo_schedular.RegRead();
        ooo_schedular.Rename();
        ooo_schedular.Decode();

        eof = ooo_schedular.Fetch(FP);
        num_of_cycles++;

    } while (ooo_schedular.Advance_Cycle(eof));

    // cout << "After do while loop" << endl;
    fclose(FP);

    // printing the final results 
    print_statistics(params, trace_file);
    return 0;
}

// Displaying the final results that is expected
// Printing the Simulator commands
// Displaying the Processor configuration 
// And printing the simulation results
void print_statistics(proc_params params, char *trace_file)
{
    instructions_per_cycle = ((float)dynamic_instruction_count / (float)num_of_cycles);

    cout << "# === Simulator Command =========\n";
    cout << "# ./sim "
         << params.rob_size << " "
         << params.iq_size << " "
         << params.width << " "
         << trace_file << "\n";

    cout << "# === Processor Configuration ===\n";
    cout << "# ROB_SIZE = " << params.rob_size << "\n";
    cout << "# IQ_SIZE  = " << params.iq_size << "\n";
    cout << "# WIDTH    = " << params.width << "\n";

    cout << "# === Simulation Results ========\n";
    cout << "# Dynamic Instruction Count    = " << dynamic_instruction_count << "\n";
    cout << "# Cycles                       = " << num_of_cycles << "\n";
    cout << fixed << setprecision(2);
    cout << "# Instructions Per Cycle (IPC) = " << instructions_per_cycle << "\n";
}

// advances through the simulator cycle
// Transitions through the pipeline stages
// returing the bool value to select which stage of the pipeline has to be executed
bool Out_of_Order_Pipeline::Advance_Cycle(bool end_of_file)
{
    // checking for the condition wherein it checks for:
    // 1. when issue queue is empty and there's no instruction waiting
    // 2. Execution list = 0
    // 3. Execute list = 0
    // 4. Writeback size = 0
    // 5. Decode, Rename, Register read and Dispatch is empty
    // returns the value true
    if (issue_queue.size() == 0 && execute_list.size() == 0 && WB.reg.size() == 0 && DE.empty && RN.empty && RR.empty && DI.empty)
    {
        if (reorder_buffer.head == reorder_buffer.tail && reorder_buffer.rob[reorder_buffer.tail].pc == 0)
        {
            pipeline_empty = true;
        }
    }

    // if the pipeline is empty and if the end of the file is reached then it returns false
    if (pipeline_empty && end_of_file)
    {
        return false;
    }

    // else it returns true
    return true;
}

// Fetch Stage of the pipeline
// 1st stage in the pipeline
// Accepting the instructions from the trace file happens at this stage
bool Out_of_Order_Pipeline::Fetch(FILE *FP)
{
    // cout << "Inside Fetch Stage" << endl;;
    bool eof = false;

    // variables are read from trace file
    int op_type; 
    int dest;
    int src1;
    int src2;

    // creating an object for class instruction
    Instruction_in_pipeline_stage instruction;

    int instruction_counter = 0;
    long long signed int pc;

    // Nothing is done if there are no more instructions and if Decode stage is not empty
    // checks for the condition wherein Decode stage is empty and the Decode size is not equal to the width
    // also checks with the conditions for when it's the end of file
    while (DE.empty == true && DE.reg.size() != ((size_t)Width) && (!(eof = fscanf(FP, "%llx %d %d %d %d", &pc, &op_type, &dest, &src1, &src2) == EOF)))
    {
        // cout << "Inside while loop" << endl;
        if (eof)
        {
            // cout << "End Of The File" << endl;
            //returning the end of file
            return eof;
        }

        // assigning values
        instruction.PC = dynamic_instruction_count;
        instruction.function_units = (operation_type)op_type;
        instruction.dst = dest;
        instruction.src_1 = src1;
        instruction.src_1_orig = src1;
        // cout << "src1 :%d\n" << src1 << endl;
        instruction.src_2 = src2;
        instruction.src_2_orig = src2;
        instruction.src1_ready = instruction.src2_ready = instruction.rs1_ROB = instruction.rs2_ROB = false;
        instruction.FE.begin_cycle = num_of_cycles;
        instruction.FE.duration = 1;
        instruction.DE.begin_cycle = num_of_cycles + 1;

        // WIDTH universal pipelines function units (FU)
        // each FU can execute any type of instruction
        // Type 0 FU has a latency of 1
        if (instruction.function_units == 0)
        {
            instruction.count = 1;
        }
        // Type 1 FU has a latency of 2
        else if (instruction.function_units == 1)
        {
            instruction.count = 2;
        }
        // Type 2 FU has a latency of 5
        else if (instruction.function_units == 2)
        {
            instruction.count = 5;
        }

        // pushing back the instruction
        DE.reg.push_back(instruction);

        // incrementing the counter values
        dynamic_instruction_count++;
        instruction_counter++;
    }

    // if the instruction counter is not zero then false is returned for DE empty
    if (instruction_counter != 0)
    {
        DE.empty = false;
    }
    /*else
    {
          cout << "DE.empty == false" << endl;
    }*/

    return eof;
}

// Decode stage of the pipeline
// 2nd stage of the pipeline
// whenever decode stage is done, the next stage it should execute is the register rename stage
// cycles count of the register rename stage is incremented
void Out_of_Order_Pipeline::Decode()
{
    // nothing is done if RN is not empty as it can't accept a new rename bundle
    // here DE is empty
    if (DE.empty == true || RN.empty == false)
    {
        return;
    }

    // for each value in the decode stage that maintains a register_log
    // incrementing the cycle count
    // and calculating the duration of decode cycle by subtracting the timestamp of DE from RN
    for (auto &reg : DE.reg)
    {
        reg.RN.begin_cycle = num_of_cycles + 1;
        reg.DE.duration = reg.RN.begin_cycle - reg.DE.begin_cycle;
    }

    // this is done when RN is empty then advancing from DE to RN
    // swapping the instruction from decode to register rename stage
    // clearing the decode stage
    DE.reg.swap(RN.reg);
    DE.reg.clear();
    DE.empty = true;
    RN.empty = false;
}

// Register rename stage of the pipeline
// next cycle after decode, i.e., 3rd stage in the pipeline
// contains the ROB entries as and when instructions are fed in
// in this stage we update the RMT entry and ROB for that particular instruction
void Out_of_Order_Pipeline::Rename()
{
    // If register rename stage contains rename bundle or register read is empty but RR is not empty then nothing is done
    if (RN.empty == true || RR.empty == false)
    {
        return;
    }

    int ROB_free_entries;

    // If the ROB head pointer is greater than the tail pointer
    // then assigning the value of ROB_Head - ROB.Tail to ROB_free_entries
    if (reorder_buffer.tail < reorder_buffer.head)
    {
        ROB_free_entries = reorder_buffer.head - reorder_buffer.tail;
    }
    // If the ROB tail pointer is greater than the Head pointer 
    // then ROB_free_entries is the total buffer size minus the subtraction of ROB Tail pointer and ROB Head pointer
    else if (reorder_buffer.head < reorder_buffer.tail)
    {
        ROB_free_entries = reorder_buffer.size - (reorder_buffer.tail - reorder_buffer.head);
    }
    // index checks for the condition wherin if the tail pointer is lesser than ROB size
    // if true then incrementing tail pointer
    // if not then decrementing tail pointer
    else
    {
        int index = (reorder_buffer.tail < (reorder_buffer.size - 1))
                      ? (reorder_buffer.tail + 1)
                      : (reorder_buffer.tail - 1);

        // recalculating ROB size of the ROB_free_entries by assigning the reorder_buffer_size
        if (reorder_buffer.rob[index].dest == 0 &&
            reorder_buffer.rob[index].pc == 0 &&
            reorder_buffer.rob[index].ready == 0)
        {
            ROB_free_entries = reorder_buffer.size;
        }
        else
        {
            ROB_free_entries = 0;
        }
    }

    // If ROB doesn't have enough entries then it does nothing
    if ((unsigned)ROB_free_entries < RN.reg.size())
    {
        return;
    } 

    // For every value in the register log in the Rename stage of pipeline
    // updating the RMT entry for that particular instruction
    for (auto &reg : RN.reg)
    {
        // Source 1 rename
        if (reg.src_1 != -1 && rename_map_table[reg.src_1].valid)
        {
            // printf("resettng src_1\n")
            reg.src_1 = rename_map_table[reg.src_1].tag;
            reg.rs1_ROB = true;
        }

        // Source 2 rename
        if (reg.src_2 != -1 && rename_map_table[reg.src_2].valid)
        {
            reg.src_2 = rename_map_table[reg.src_2].tag;
            reg.rs2_ROB = true;
        }

        // Filling the ROB register
        auto &rob_entry = reorder_buffer.rob[reorder_buffer.tail];

        // Filling that particular ROB entry
        rob_entry.dest = reg.dst;
        rob_entry.pc = reg.PC;
        rob_entry.ready = false;

        // Updating the rename_map_table, i.e, RMT
        // rolling the tag of the reorder buffer table
        // making the entry before tail pointer to be valid
        if (reg.dst != -1)
        {
            rename_map_table[reg.dst].tag = reorder_buffer.tail;
            rename_map_table[reg.dst].valid = true;
        }

        // Updating the instruction dst to ROB index
        reg.dst = reorder_buffer.tail;

        // Incrementing the tail pointer in circular fashion
        // if it's not equal to ROB size, then incrementing the tail
        // if not then assigning zero to it
        if (reorder_buffer.tail != reorder_buffer.size - 1)
        {
            reorder_buffer.tail++;
        }
        else
        {
            reorder_buffer.tail = 0;
        }

        // Updating the timing, i.e, the cycle count
        reg.RR.begin_cycle = num_of_cycles + 1;
        // calculating the RN duration by subtracting RN timestamp from RR
        reg.RN.duration = reg.RR.begin_cycle - reg.RN.begin_cycle;
    }

    // this is done when RR is empty and ROB has enough free enteries to accept the entire rename bundle
    // Swapping the values between RN and RR stage of the pipeline 
    // clearing the RN register log
    RN.reg.swap(RR.reg);
    RN.reg.clear();
    RN.empty = true;
    RR.empty = false;
}

// Register Read stage of the pipeline
// 4th stage in the pipeline
// Reads out from the architectural register file (ARF)
void Out_of_Order_Pipeline::RegRead()
{
    // If RR contains the register read bundle or if DI is non empty then return nothing
    if (RR.empty != false || DI.empty != true)
    {
        return;
    }

    // Register-read bundle and advancing it from RR to DI
    // for each of the values in the register log in RegRead stage
    for (auto &reg : RR.reg)
    {
        // Source 1 register
        if (reg.rs1_ROB)
        {
            if (reorder_buffer.rob[reg.src_1].ready)
            {
                reg.src1_ready = true;
            }
        }
        else
        {
            reg.src1_ready = true;
        }

        // Source 2 register
        if (reg.rs2_ROB)
        {
            if (reorder_buffer.rob[reg.src_2].ready)
            {
                reg.src2_ready = true;
            }
        }
        else
        {
            reg.src2_ready = true;
        }

        // Timing update
        reg.DI.begin_cycle = num_of_cycles + 1;

        // RR duration is obtained from subtracting the start cycle of RR from DI
        reg.RR.duration = reg.DI.begin_cycle - reg.RR.begin_cycle;
    }

    // once DI becomes empty the proceeding it from RR to DI
    // Swapping the values between RR and DI stage of the pipeline
    // clearing out the RR register
    RR.reg.swap(DI.reg);
    RR.reg.clear();
    RR.empty = true;
    DI.empty = false;
}

// Dispatch stage of the pipeline
// 5th stage of the pipeline
// from this stage, the instruction goes into the IQ and stays there depending on the dependancy
void Out_of_Order_Pipeline::Dispatch()
{
    // as and when the instruction leaves the IQ stage, freeing the space
    int free_IQ_entries = params.iq_size - (int)issue_queue.size();

    // If DI contains the dispatch bundle or if free IQ is less than the size of DI then return nothing
    if (DI.empty == true || free_IQ_entries < (int)DI.reg.size()) 
    {
        return;
    }

    // DI read bundle and advancing it from DI to IQ
    // for each register in DI stage of the pipeline
    for (auto &instr : DI.reg)
    {
        instr.IS.begin_cycle = num_of_cycles + 1;
        instr.DI.duration = instr.IS.begin_cycle - instr.DI.begin_cycle;

        issue_queue.push_back(instr);
    }

    // clearing out the registers in DI stage
    DI.reg.clear();
    DI.empty = true;
}

// Issue stage of the pipeline
// 6th stage in the pipeline
// instructions are stored in this stage depending on the dependancy on one other
// if the instruction that has entered into the IQ depends on previous instruction then it stays in the IQ until the previous has passed WB
// if the instruction isn't dependent on the previous instruction then it just stays in the IQ for 1 clock cycle
void Out_of_Order_Pipeline::Issue()
{
    // if IQ is empty then it returns nothing
    if (issue_queue.empty())
    {
        // cout << "Issue Queue Is Empty" << endl;
        return;
    }

    // sorting the IQ from begin to end
    sort(issue_queue.begin(), issue_queue.end());

    int issued = 0;
    bool progress = true;

    // Checking if the progress and issued instruction that is in IQ is less than the width of the IQ
    while (progress && issued < Width)
    {
        progress = false;

        // advancing through the IQ
        for (int j = 0; j < (int)issue_queue.size(); j++)
        {
            // when both the source operands are ready
            // if both are ready then we move to execute list
            if (issue_queue[j].src1_ready && issue_queue[j].src2_ready)
            {
                issue_queue[j].EX.begin_cycle = num_of_cycles + 1;
                issue_queue[j].IS.duration = issue_queue[j].EX.begin_cycle - issue_queue[j].IS.begin_cycle;
                execute_list.push_back(issue_queue[j]);
                issue_queue.erase(issue_queue.begin() + j);
                issued++;
                progress = true;
                break;
            }
        }
    }
}

// Execute stage of the pipeline
// 7th stage in the pipeline
// contains the simple ALU, complex ALU, the agen and data cache 
// if it's a load instruction then it first moves into the agen and then to the data cache 
// if it's just ALU instruction then it goes to the simple ALU
// executing the instruction for the required latency depending on the FU type
void Out_of_Order_Pipeline::Execute()
{
    bool progress = true;

    // If the execute list is empty then return nothing
    if (execute_list.empty())
    {
        return;
    }

    // checking for the instruction that are finishing execution in present cycle
    // Removing the instrction from the Execution list
    for (int i = 0; i < (int)execute_list.size(); i++)
    {
        execute_list[i].count -= 1;
    }

    // While the instruction is in progress
    // progressing through the execute list
    while (progress)
    {
        progress = false;

        for (int i = 0; i < (int)execute_list.size(); i++)
        {
            // if execute_list count = 0 then moving it to the WB stage
            if (execute_list[i].count == 0)
            {
                execute_list[i].WB.begin_cycle = num_of_cycles + 1;
                execute_list[i].EX.duration = execute_list[i].WB.begin_cycle - execute_list[i].EX.begin_cycle;

                // Adding the Instruction to WB stage
                WB.reg.push_back(execute_list[i]);

                // Wakeup dependent instructions 
                // the wakeup instruction goes from EX to IQ
                // setting their soruce operand ready flags in IQ, DI & RR
                // RR stage
                for (int j = 0; j < (int)RR.reg.size(); j++)
                {
                    if (execute_list[i].dst == RR.reg[j].src_1)
                    {
                        RR.reg[j].src1_ready = true;
                    }

                    if (execute_list[i].dst == RR.reg[j].src_2)
                    {
                        RR.reg[j].src2_ready = true;
                    }
                }

                // IQ stage
                // setting the ready flags for source register 1 and 2
                for (int j = 0; j < (int)issue_queue.size(); j++)
                {
                    if (execute_list[i].dst == issue_queue[j].src_1)
                    {
                        issue_queue[j].src1_ready = true;
                    }

                    if (execute_list[i].dst == issue_queue[j].src_2)
                    {
                        issue_queue[j].src2_ready = true;
                    }
                }

                // DI stage
                // setting the ready flags for source register 1 and 2
                for (int j = 0; j < (int)DI.reg.size(); j++)
                {
                    if (execute_list[i].dst == DI.reg[j].src_1)
                    {
                        DI.reg[j].src1_ready = true;
                    }

                    if (execute_list[i].dst == DI.reg[j].src_2)
                    {
                        DI.reg[j].src2_ready = true;
                    }
                }

                execute_list.erase(execute_list.begin() + i);
                progress = true;
                break;
            }
        }
    }
}

// Writeback stage of the pipeline
// 8th stage in the pipeline
// This stage writebacks the value to the ALU, IQ and ROB
// This ensures that computed value gets updated in thr ROB and ARF entry
// The duration of WB stage of the pipeline is calculated by subtracting the cycle count of WB from RT
void Out_of_Order_Pipeline::Writeback()
{
    for (int i = 0; i < (int)WB.reg.size(); i++)
    {
        // Marking the ROB entry as ready
        reorder_buffer.rob[WB.reg[i].dst].ready = true;
        WB.reg[i].RT.begin_cycle = num_of_cycles + 1;
        WB.reg[i].WB.duration = WB.reg[i].RT.begin_cycle - WB.reg[i].WB.begin_cycle;
        // moving the instruction to the retire stage
        RT.reg.push_back(WB.reg[i]);
    }

    // clearing the values in the register log in the WB stage
    WB.reg.clear();
}

// Retire stage of the pipeline
// After it finished the retire stage of the pipeline the subsequent entry from the ROB is emptied
// The RMT entry is also driven out
// retire up to Width consecutive "ready" instructions from head of ROB (reorder_buffer)
void Out_of_Order_Pipeline::Retire()
{
    int retired = 0;

    // checking if the retired instruction is less than the width
    while (retired < Width)
    {
        if (reorder_buffer.rob[reorder_buffer.head].ready)
        {
            // printing the results
            for (auto i_retire = RT.reg.begin(); i_retire != RT.reg.end(); ++i_retire)
            {
                if (i_retire->PC == reorder_buffer.rob[reorder_buffer.head].pc)
                {
                    i_retire->RT.duration = (num_of_cycles + 1) - i_retire->RT.begin_cycle;

                    // printing what happens in each of the stage of the pipeline
                    cout << i_retire->PC << " fu{" << i_retire->function_units << "} src{" << i_retire->src_1_orig << "," << i_retire->src_2_orig << "} ";
                    cout << "dst{" << reorder_buffer.rob[reorder_buffer.head].dest << "} FE{" << i_retire->FE.begin_cycle << "," << i_retire->FE.duration << "} ";
                    cout << "DE{" << i_retire->DE.begin_cycle << "," << i_retire->DE.duration << "} RN{" << i_retire->RN.begin_cycle << "," << i_retire->RN.duration << "} ";
                    cout << "RR{" << i_retire->RR.begin_cycle << "," << i_retire->RR.duration << "} DI{" << i_retire->DI.begin_cycle << "," << i_retire->DI.duration << "} ";
                    cout << "IS{" << i_retire->IS.begin_cycle << "," << i_retire->IS.duration << "} EX{" << i_retire->EX.begin_cycle << "," << i_retire->EX.duration << "} ";
                    cout << "WB{" << i_retire->WB.begin_cycle << "," << i_retire->WB.duration << "} RT{" << i_retire->RT.begin_cycle << "," << i_retire->RT.duration << "}";
                    cout << endl;

                    // erasing the contents in the retire stage
                    RT.reg.erase(i_retire);
                    break;
                }
            }

            // RR stage
            // setting the ready flag to the source registers if it's equal to the ROB head pointer
            for (int j = 0; j < (int)RR.reg.size(); j++)
            {
                if (RR.reg[j].src_1 == reorder_buffer.head)
                {
                    RR.reg[j].src1_ready = true;
                }

                if (RR.reg[j].src_2 == reorder_buffer.head)
                {
                    RR.reg[j].src2_ready = true;
                }
            }

            // RMT process
            // if the RMT table tag is equal to the reorder buffer head 
            // then eliminating or removing the entry from RMT
            // this happens when the instruction leaves the pipeline
            // essentially after the instruction reaches the RT stage of the pipeline
            for (size_t z = 0; z < (size_t)(sizeof(rename_map_table) / sizeof(rename_map_table[0])); z++)
            {
                if (rename_map_table[z].tag == reorder_buffer.head)
                {
                    rename_map_table[z].tag = 0;
                    rename_map_table[z].valid = false;
                }
            }

            // reintialising the ROB contents to 0
            memset((void *)&reorder_buffer.rob[reorder_buffer.head], 0, sizeof(ROB_Table));

            // once the instruction is retired from the pipeline
            // then incrementing the head pointer of ROB table to point to the next entry
            // else the head pointer of the rob table stays in the same location
            if (reorder_buffer.head != (reorder_buffer.size - 1))
            {
                reorder_buffer.head++;
            }
            else
            {
                reorder_buffer.head = 0;
            }

            // incrementing the retired instruction count
            // keeping track of the retired instructions
            retired++;
        }
        else
        {
            break;
        }
    }
}