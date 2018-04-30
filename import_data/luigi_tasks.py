import luigi
import invoke
from invoke import Context, Config

import tasks as invoke_tasks


class InvokeContext:
    @classmethod
    def get(cls):
        conf = Config(project_location='.')
        conf.load_project()
        return Context(conf)


class importOsmConfig(luigi.Config):
    import_id = luigi.Parameter()
    pbf_url = luigi.Parameter()
    osm_file = luigi.Parameter()


class ImportPipelineTask(luigi.Task):
    def __init__(self, *args, **kwargs):
        self.config = importOsmConfig()
        super().__init__(*args, **kwargs)

    def output(self):
        return luigi.LocalTarget(
            path='/tmp/import_pipeline/{import_id}/{task_name}.done'.format(
                import_id=self.config.import_id,
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
    osm_file = luigi.Parameter()

    def run(self):
        invoke.run(f'wget {self.config.pbf_url} -O {self.osm_file}')

    def output(self):
        return luigi.LocalTarget(
            path=self.osm_file
        )


class LoadBaseMapTask(ImportPipelineTask):
    def requires(self):
        yield DownloadPbfTask(osm_file=self.config.osm_file)

    def run(self):
        invoke_context = InvokeContext.get()
        invoke_context.osm_file = self.config.osm_file
        self.invoke_task_and_write_output('load_basemap', ctx=invoke_context)


class LoadPoiTask(ImportPipelineTask):
    def requires(self):
        yield DownloadPbfTask(osm_file=self.config.osm_file)

    def run(self):
        invoke_context = InvokeContext.get()
        invoke_context.osm_file = self.config.osm_file
        self.invoke_task_and_write_output('load_poi', ctx=invoke_context)


class LoadOmtSqlTask(ImportPipelineTask):
    def requires(self):
        yield LoadBaseMapTask()
        yield LoadPoiTask()

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
        yield LoadOmtSqlTask()
        yield LoadNaturalEarthTask()
        yield LoadWaterTask()
        yield LoadLakeTask()
        yield LoadBorderTask()

    def run(self):
        self.invoke_task_and_write_output('run_post_sql_scripts')


class GenerateTiles(ImportPipelineTask):
    # tilerator_api_url = luigi.Parameter()

    def requires(self):
        yield PostSqlTask()

    def run(self):
        print('Generating tiles....')
