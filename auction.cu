#include <cstdlib>
#include <iostream>
#include <string>
#include <fstream>
#include <cuda_profiler_api.h>

#include <stdio.h>
#include <stdlib.h>
#include <vector>
#include "auction.cuh"

#include <chrono>
#define MAXMY 0x3f3f3f3f
using namespace std;
typedef std::chrono::high_resolution_clock::rep hr_clock_rep;

inline hr_clock_rep get_globaltime(void) 
{
	using namespace std::chrono;
	return high_resolution_clock::now().time_since_epoch().count();
}

// Returns the period in miliseconds
inline double get_timer_period(void) 
{
	using namespace std::chrono;
	return 1000.0 * high_resolution_clock::period::num / high_resolution_clock::period::den;
}
__device__ int kflag;
#if DEBUG
__device__ int tans;
#endif
__device__ int minRise;
__device__ int kpoCount;
__device__ int knaCount;
__device__ int kpushListPo[SIZE][2];
__device__ int kpushListNa[SIZE][2];
__device__ bool knodesRisePrice[SIZE];

__device__ void printNodes(const int* nodes, int numNodes, const char* name){
	printf("*******************\n");
	printf(name);
	printf("\n");
	for(int i = 0; i < numNodes; i++){
		printf("%d\t", nodes[i]);
	}
	printf("\n*******************\n");
}
__device__ void printGraph(const int* graph, int numNodes, const char* name){
	printf("*******************\n");
	printf("%d", numNodes);
	printf(name);
//	for(int i = 0; i < numNodes; i++){
//		for(int j = 0; j < numNodes; j++){
//			printf("%d\t", graph[i*numNodes + j]);
//		}
//		printf("\n");
//	}
	printf("*******************\n");
}

__device__ unsigned int justForTest = 0;
__device__ void dcostScalingInit(
		const int costScale,
		const int gdelta,
		const int C,
		const int ledges,
		const int redges,
		const int lnodes,
		const int rnodes,
		const int knumNodes,
		const int* edges,
		const int* costRaw,
		int* cost,
		int* price){
	int ti,tj;
	for(int i = ledges; i < redges; i++){
		ti = edges[i*2 + 0];
		tj = edges[i*2 + 1];
		if(costRaw[ti*knumNodes + tj] <= C){
			cost[ti*knumNodes + tj] = costRaw[ti*knumNodes + tj]/(1 << costScale);
		}
	}
	for(int i = lnodes; i < rnodes; i++){
		price[i]*=(1 << gdelta);
	}
	return;
}
//pushlist is not good
__device__ void pushFlow(
		Graph &G,
		const int lnodes,
		const int rnodes,
		const int ledges,
		const int redges,
		const int epsilon,
		const int knumNodes,
		int* kflow,
		const int* kprice,
		const int* kcost
		){
#if FULLDEBUG
	if(threadIdx.x ==0){
		printf("in pushFlow\n");
	}
	__syncthreads();
#endif
	if(threadIdx.x ==0){
		kpoCount = 0;
		knaCount = 0;
	}
	__syncthreads();

	for(int i = ledges; i < redges; i++){
		int ti,tj,tindex;
		ti = G.edge2source(i);
		tj = G.edge2sink(i);
		if(kcost[ti*knumNodes + tj] - kprice[ti] + kprice[tj] + epsilon == 0&&G.atGrow(ti) >0){
			tindex = atomicAdd(&kpoCount, 1);
			kpushListPo[tindex][0] = ti;
			kpushListPo[tindex][1] = tj;
			continue;
		}
		if(kcost[ti*knumNodes + tj] - kprice[ti] + kprice[tj] - epsilon == 0&&G.atGrow(tj) > 0){
			tindex = atomicAdd(&knaCount, 1);
			kpushListNa[tindex][0] = tj;
			kpushListNa[tindex][1] = ti;
			continue;
		}
	}
#if FULLDEBUG
	if(threadIdx.x ==0){
		printf("get pushList\n");
	}
	__syncthreads();
#endif
	__syncthreads();
	int delta,tmpi,tmpj;
	if(threadIdx.x == 0){
		for(int i = 0; i < kpoCount; i++){
			tmpi = kpushListPo[i][0];
			tmpj = kpushListPo[i][1];
			delta = min(G.atGrow(tmpi), G.atRb(tmpi,tmpj) - kflow[tmpi*knumNodes + tmpj]);
			kflow[tmpi*knumNodes + tmpj] += delta;
			G.atomicSubGrow(tmpi, delta);
			G.atomicAddGrow(tmpj, delta);
		}
		for(int i = 0; i < knaCount; i++){
			tmpi = kpushListNa[i][0];
			tmpj = kpushListNa[i][1];
			delta = min(G.atGrow(tmpi), kflow[tmpj*knumNodes + tmpi] - G.atLb(tmpj,tmpi));
			kflow[tmpj*knumNodes + tmpi] -= delta;
			G.atomicSubGrow(tmpi, delta);
			G.atomicAddGrow(tmpj, delta);
		}
	}
	__syncthreads();
#if FULLDEBUG
		if(threadIdx.x == 0){
			printf("out pushFlow\n");
		}
		__syncthreads();
#endif

	return ;
}
__device__ void priceRise(
		Graph &G,
		const int lnodes,
		const int rnodes,
		const int ledges,
		const int redges,
		const int epsilon,
		const int knumNodes,
		const int* kflow,
		const int* kprice,
		const int* kcost
		){
#if FULLDEBUG
		if(threadIdx.x == 0){
			printf("in priceRise\n");
		}
		__syncthreads();
#endif

	int ti,tj,swap,tmpa,tmpb;
	for(int i = lnodes; i < rnodes; i++){
		if(G.atGrow(i) > 0){
			knodesRisePrice[i] = true;
		}else {
			knodesRisePrice[i] = false;
		}
	}
	__syncthreads();
	for(int i = ledges; i < redges; i++){
		ti = G.edge2source(i);
		tj = G.edge2sink(i);
		if(knodesRisePrice[ti]!=knodesRisePrice[tj]){
			if(kflow[ti*knumNodes + tj] < G.atRb(ti,tj)&&knodesRisePrice[ti]){
				tmpb = kprice[tj] + kcost[ti*knumNodes + tj] + epsilon - kprice[ti];
				if(tmpb >= 0){
					atomicMin(&minRise, tmpb);
				}
			}
			if(kflow[ti*knumNodes + tj] > G.atLb(ti,tj)&&knodesRisePrice[tj]){
				tmpa = kprice[ti] - kcost[ti*knumNodes + tj] + epsilon - kprice[tj];
				if(tmpa >= 0){
					atomicMin(&minRise, tmpa);
				}
			}
		}
	}
#if FULLDEBUG
		if(threadIdx.x == 0){
			printf("out priceRise\n");
		}
		__syncthreads();
#endif
	__syncthreads();

}
__global__ void __launch_bounds__(1024, 1)
auction_algorithm_kernel(
		Graph G,
		const int kthreadNum,
		const int kC,

		int* kcost,
		int* kprice,
		int* kflow){
	const int threadId = threadIdx.x;

	
	if(threadId == 0){
		printf("in kernel\n");
	}
	__syncthreads();

	int knumNodes = G.getNodesNum();
	int knumEdges = G.getEdgesNum();

	int kepsilon = 1;
	int edgesDivThread;
	int edgesModThread;
	//[edgesl,edgesr) is the range of edges that the thread produre
	int ledges;
	int redges;

	int nodesDivThread;
	int nodesModThread;
	int lnodes;
	int rnodes;

	int totalIteratorNum = 0;
	int iteratorNum = 0;
	int scalingFactor = 2;
	int costScale = 9;
	int gdelta = 0;

	int kti;
	int ktj;

	edgesDivThread = knumEdges/kthreadNum;
	edgesModThread = knumEdges%kthreadNum;
	
	if(threadId < edgesModThread){
		ledges = threadId*(edgesDivThread + 1);
		redges = (threadId + 1)*(edgesDivThread + 1);
	}else {
		ledges = threadId*edgesDivThread + edgesModThread;
		redges = (threadId + 1)*edgesDivThread + edgesModThread;
	}
	
	nodesDivThread = knumNodes/kthreadNum;
	nodesModThread = knumNodes%kthreadNum;

	if(threadId < nodesModThread){
		lnodes = threadId*(nodesDivThread + 1);
		rnodes = (threadId + 1)*(nodesDivThread + 1);
	}else{
		lnodes = threadId*nodesDivThread + nodesModThread;
		rnodes = (threadId + 1)*nodesDivThread + nodesModThread;
	}

	while(costScale >= 0){
#if DEBUG
		if(threadId == 0){
			printf("cost scale: %d\n",costScale);
		}
#endif
		for(int i = lnodes; i < rnodes; i++){
			G.setGrow(i , G.atGrowRaw(i));
		}

		int ktmp = 1<<costScale;

		for(int i = ledges; i < redges; i++){
			kti = G.edge2source(i);
			ktj = G.edge2sink(i);
			kflow[kti * knumNodes + ktj] = 0;
			if(G.atCostRaw(kti,ktj) <= kC){
				kcost[kti*knumNodes + ktj] = G.atCostRaw(kti,ktj)/ktmp;
			}
		}
		for(int i = lnodes; i < rnodes; i++){
			kprice[i]*=(1 << gdelta);
		}
		__syncthreads();
		for(int i = ledges; i < redges; i++){
				kti = G.edge2source(i);
				ktj = G.edge2sink(i);
				if(kcost[kti*knumNodes+ktj] - kprice[kti] + kprice[ktj] + kepsilon <= 0){
					G.atomicSubGrow(kti, G.atRb(kti,ktj));
					G.atomicAddGrow(ktj, G.atRb(kti,ktj));
					kflow[kti*knumNodes+ktj] = G.atRb(kti,ktj);
				}
		}
		iteratorNum = 0;
		if(threadId == 0)
		{
			kflag = true;
		}
		__syncthreads();

		for(int i = lnodes; i < rnodes; i++){
			if(G.atGrow(i) != 0){
				atomicAnd(&kflag, 0);
			}
		}
		__syncthreads();

		while(!kflag){
#if FULLDEBUG
			if(threadId == 0){
				printf("iteration : %d\n", iteratorNum);
			}
			__syncthreads();
#endif
			pushFlow(
					G,
				lnodes,
				rnodes,
				ledges,
				redges,
				kepsilon,
				knumNodes,
				kflow,
				kprice,
				kcost
				);
			if(threadId == 0){
				minRise = MAXMY;
			}
			__syncthreads();
			priceRise(
					G,
				lnodes,
				rnodes,
				ledges,
				redges,
				kepsilon,
				knumNodes,
				kflow,
				kprice,
				kcost
				);
			__syncthreads();
#if FULLDEBUG
			if(threadId == 0){
				printf("minRise: %d\n", minRise);
			}
			__syncthreads();
#endif
			if(threadId == 0){
				if(minRise == MAXMY){
					minRise = 0;
				}
			}

			__syncthreads();
			for(int i = lnodes; i < rnodes; i++){
				if(knodesRisePrice[i]){
					kprice[i] += minRise;
				}
			}
			__syncthreads();
			iteratorNum++;
			totalIteratorNum++;
			if(threadId == 0)
			{
				kflag = true;
			}
			for(int i = lnodes; i < rnodes; i++){
				if(G.atGrow(i) != 0){
					atomicAnd(&kflag, 0);
				}
			}
			__syncthreads();

#if FULLDEBUG
			if(threadId == 0){
				printNodes(kg, knumNodes, "kg");
				printNodes(kprice, knumNodes, "kprice");
			}
			__syncthreads();
#endif
		}

#if DEBUG
		if(threadId == 0){
			tans = 0;
		}
		__syncthreads();
		for(int i = ledges; i < redges; i++){
			kti = G.edge2source(i);
			ktj = G.edge2sink(i);
			atomicAdd(&tans, kflow[kti*knumNodes + ktj]*G.atCostRaw(kti,ktj));
		}
		if(threadId == 0){
			printf("inner loop out\n");
			printf("temporary ans: %d\n",tans);
			printf("cost scale: %d\n", costScale);
		}
		__syncthreads();
#endif
		if(costScale ==0){
			break;
		}
		gdelta = costScale - max(0, costScale - scalingFactor);
		costScale = max(0, costScale - scalingFactor);
	}


	if(threadId == 0)
	{
		printGraph(kcost, knumNodes,"cost");
		printf("kenerl end\n");
	}
	__syncthreads();
}
hr_clock_rep timer_start, timer_mem, timer_stop;

void run_auction(
		Graph auctionGraph,
		int numNodes,
		int numEdges,
		int threadNum,
		int dC,

		int* hedges,
		int* hcost,
		int* hg,
		int* hlb,
		int* hrb,

		int* hflow){
	cout << "start run_auction\n";
	int* dedges;
	int* dcost;
	int* dcostRaw;
	int* dg;
	int* dgraw;
	int* dlb;
	int* drb;

	int* dprice;

	int* dflow;

	timer_start = get_globaltime();
	cudaMalloc((void **)&dedges, EDGESIZE*2*sizeof(int));
	cudaMalloc((void **)&dcost, SIZE*SIZE*sizeof(int));
	cudaMalloc((void **)&dcostRaw, SIZE*SIZE*sizeof(int));
	cudaMalloc((void **)&dg, SIZE*sizeof(int));
	cudaMalloc((void **)&dgraw, SIZE*sizeof(int));
	cudaMalloc((void **)&dlb, SIZE*SIZE*sizeof(int));
	cudaMalloc((void **)&drb, SIZE*SIZE*sizeof(int));

	cudaMalloc((void **)&dprice, SIZE*sizeof(int));

	cudaMalloc((void **)&dflow, SIZE*SIZE*sizeof(int));


	cudaMemcpy(dedges, hedges, EDGESIZE*2*sizeof(int), cudaMemcpyHostToDevice);
	
	cudaMemcpy(dcost, hcost, SIZE*SIZE*sizeof(int), cudaMemcpyHostToDevice);
	cudaMemcpy(dcostRaw, hcost, SIZE*SIZE*sizeof(int), cudaMemcpyHostToDevice);

	cudaMemcpy(dg, hg, SIZE*sizeof(int), cudaMemcpyHostToDevice);
	cudaMemcpy(dgraw, hg, SIZE*sizeof(int), cudaMemcpyHostToDevice);

	cudaMemcpy(dlb, hlb, SIZE*SIZE*sizeof(int), cudaMemcpyHostToDevice);
	cudaMemcpy(drb, hrb, SIZE*SIZE*sizeof(int), cudaMemcpyHostToDevice);

	timer_mem = get_globaltime();
	cudaProfilerStart();
	cout << "start kernel\n";
	auction_algorithm_kernel<<<1,threadNum>>>
		(

		auctionGraph,
		threadNum,
		dC,
		dcost,
		dprice,
		dflow);
	cudaProfilerStop();
	cudaDeviceSynchronize();
	timer_stop = get_globaltime();
	cudaMemcpy(hflow, dflow, SIZE*SIZE*sizeof(int), cudaMemcpyDeviceToHost);
	
	int ans = 0;
	for(int i = 0; i < numNodes; i++){
		for(int j = 0; j < numNodes; j++){
			ans += hflow[i*numNodes + j]*hcost[i*numNodes+ j];
//			cout << hflow[i*numNodes + j] << " ";
		}
	}
	cout << "ans:  " << ans << endl;

}


void initmy(
		int *dc,
		int *edges,
		int *cost,
		int *hg,
		int *lb,
		int *rb){
	cout << "start read in graph..\n";
	int tnumNodes;
	int tCapacity = 0;
	int tmaxCost = 0;
	cin >> tnumNodes;
	cout << "tnumNodes: "<< tnumNodes << endl;
	memset(cost, MAXMY, sizeof(cost));
	memset(edges, 0, sizeof(edges));
	memset(hg, 0, sizeof(hg));
	char a;
	int fid;
	int aNUm;
	cin >> aNUm;
//	cout << "aNUm " << aNUm << endl;
	for(int i = 0; i < aNUm; i++){
		cin >> a >> fid;
		cin >> hg[fid-1];
//		cout << a << " " << fid << " " << g[fid-1] << endl;
	}
	int ti,tj;
	int edgeNum = 0;
	while(true){
		cin >> a >> ti >> tj;
		if(ti == tj&&ti==0){
			break;
		}
		ti--;tj--;
		edges[edgeNum*2] = ti;
		edges[edgeNum*2 + 1] = tj;
		edgeNum++;

		cin >> lb[ti*SIZE + tj] >> rb[ti*SIZE + tj] >>  cost[ti*SIZE + tj] ;
//		cout << a << "\t" << ti << " " << tj << " " << cost[ti*SIZE + tj] <<" " << lb[ti*SIZE + tj] << " " << rb[ti*SIZE + tj] <<  endl;
//		cost[ti][tj] *= nodeNum;
//		cost[ti][tj] %= 4000;
		tmaxCost = max(cost[ti*SIZE + tj], tmaxCost);
		tCapacity = max(rb[ti*SIZE + tj], tCapacity);
	}
	*dc = tmaxCost;
	cout << "read end\n";
}

int main(int argc, char *argv[]){
	int threadNum = 1024;
	int numNodes = SIZE;
	int numEdges = EDGESIZE;
	int hC;
	int *hedges = new int[EDGESIZE*2];
	int *hcost = new int[SIZE*SIZE];
	int *hg = new int[SIZE];
	int *hlb = new int[SIZE*SIZE];
	int *hrb = new int[SIZE*SIZE];

	int *hflow = new int[SIZE*SIZE];
	memset(hflow, 0, sizeof(hflow));

	initmy(
		&hC,
		hedges,
		hcost,
		hg,
		hlb,
		hrb
		
	);

	Graph auctionGraph = Graph(numNodes, numEdges, hedges, hcost, hlb, hrb, hg);

	run_auction(
			auctionGraph,
		numNodes,
		numEdges,
		threadNum,
		hC,

		hedges,
		hcost,
		hg,
		hlb,
		hrb,

		hflow
	);

	std::cerr << "run_acution takes "<< (timer_stop - timer_start)*get_timer_period() << "ms totally.\n";
	std::cerr << "memory copy takes "<< (timer_mem - timer_start)*get_timer_period() << "ms totally.\n";
	std::cerr << "kernel takes "<< (timer_stop - timer_mem)*get_timer_period() << "ms totally.\n";
	return 0;
}
