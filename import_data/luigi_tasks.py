import luigi
import time
import invoke
from invoke import Context, Config

import tasks as invoke_tasks

OSM_FILE = '/data/osm.pbf'

class InvokeContext:
    @classmethod
    def get(cls):
        conf = Config(project_location='.')
        conf.load_project()
        return Context(conf)


class ImportPipelineTask(luigi.Task):
    seed = luigi.Parameter(positional=False)
    pbf_url = luigi.OptionalParameter(positional=False)

    def output(self):
        return luigi.LocalTarget(
            path='/tmp/import_pipeline/{seed}/{task_name}.done'.format(
                seed=self.seed,
                task_name=self.__class__.__name__
            )
        )

    def invoke_task_and_write_output(self, task_name, ctx=None):
        if ctx is None:
            ctx = InvokeContext.get()
        getattr(invoke_tasks, task_name)(ctx)
        with self.output().open('w') as output:
            output.write('')


### Pipeline Tasks
#########################

class DownloadPbfTask(ImportPipelineTask):
    osm_file = luigi.Parameter(default=OSM_FILE)

    def run(self):
        invoke.run(f'wget {self.pbf_url} -O {self.osm_file}')

    def output(self):
        return luigi.LocalTarget(
            path=self.osm_file
        )


class LoadBaseMapTask(ImportPipelineTask):
    osm_file = luigi.Parameter(default=OSM_FILE)

    def requires(self):
        yield self.clone(cls=DownloadPbfTask, osm_file=self.osm_file)

    def run(self):
        invoke_context = InvokeContext.get()
        invoke_context.osm_file = self.osm_file
        self.invoke_task_and_write_output('import_basemap', ctx=invoke_context)


class LoadPoiTask(ImportPipelineTask):
    osm_file = luigi.Parameter(default=OSM_FILE)

    def requires(self):
        yield self.clone(cls=DownloadPbfTask, osm_file=self.osm_file)

    def run(self):
        invoke_context = InvokeContext.get()
        invoke_context.osm_file = self.osm_file
        self.invoke_task_and_write_output('import_poi', ctx=invoke_context)


class LoadOmtSqlTask(ImportPipelineTask):
    def requires(self):
        yield self.clone(cls=LoadBaseMapTask)
        yield self.clone(cls=LoadPoiTask)

    def run(self):
        self.invoke_task_and_write_output('run_sql_script')


class LoadNaturalEarthTask(ImportPipelineTask):
    def run(self):
        self.invoke_task_and_write_output('import_natural_earth')


class LoadWaterTask(ImportPipelineTask):
    def run(self):
        self.invoke_task_and_write_output('import_water_polygon')


class LoadLakeTask(ImportPipelineTask):
    def run(self):
        self.invoke_task_and_write_output('import_lake')


class LoadBorderTask(ImportPipelineTask):
    def run(self):
        self.invoke_task_and_write_output('import_border')


class PostSqlTask(ImportPipelineTask):
    def requires(self):
        yield self.clone(LoadOmtSqlTask)
        yield self.clone(LoadNaturalEarthTask)
        yield self.clone(LoadWaterTask)
        yield self.clone(LoadLakeTask)
        yield self.clone(LoadBorderTask)

    def run(self):
        self.invoke_task_and_write_output('run_post_sql_scripts')


class GenerateTiles(ImportPipelineTask):
    # tilerator_api_url = luigi.Parameter()

    def requires(self):
        yield self.clone(PostSqlTask)

    def run(self):
        print('Generating tiles....')
